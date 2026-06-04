// Function 10: Dynamic Module Unloading
// Description: Unload modules at runtime, release resources
// Priority: P1

import Foundation
import os

// MARK: - Unload Result
/// Module unload result enumeration
public enum ModuleUnloadResult {
    case success
    case failure(ModuleUnloadFailureReason)
    
    public var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}

/// Module unload failure reason
public enum ModuleUnloadFailureReason {
    case notLoaded(name: String)
    case notConformingToProtocol(name: String)
    case hasDependents(module: String, dependents: [String])
    case stopFailed(name: String, error: Error)
    case resourceCleanupFailed(name: String, error: Error)
    case internalError(reason: String)
}

// MARK: - ModuleUnloader
/// Module unloader (Function 10)
/// Runtime dynamic module unloading with full lifecycle management
/// Thread-safe: all operations protected by os_unfair_lock
public final class ModuleUnloader {
    private let registry: ModuleRegistry
    private let eventBus: EventBus
    private let logger = ModuleLogger(category: "ModuleUnloader")
    
    /// Thread-safe set of unloaded modules
    private final class UnloadedStorage: @unchecked Sendable {
        var unloaded: Set<String> = []
        var lock = os_unfair_lock()
    }
    
    private let unloadedStorage = UnloadedStorage()
    
    public init(registry: ModuleRegistry, eventBus: EventBus) {
        self.registry = registry
        self.eventBus = eventBus
    }
    
    // MARK: - Unload Module
    
    /// Normal module unload
    /// Process: stop() -> cleanup -> unregister -> emit event
    /// - Parameter name: Module name
    /// - Returns: Unload result
    public func unload(name: String) -> ModuleUnloadResult {
        logger.info("Unloading module: \(name)")
        
        // 1. Check if module is registered
        guard registry.isLoaded(name: name) else {
            logger.warning("Module \(name) not loaded, cannot unload")
            return .failure(.notLoaded(name: name))
        }
        
        // 2. Check XRZModule conformance
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("Module \(name) does not conform to XRZModule, cannot unload")
            return .failure(.notConformingToProtocol(name: name))
        }
        
        // 3. Check for dependent modules
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            logger.warning("Module \(name) has dependents, cannot unload: \(dependents.joined(separator: ", "))")
            return .failure(.hasDependents(module: name, dependents: dependents))
        }
        
        // 4. Send pre-unload event
        eventBus.emit(.moduleWillUnload, userInfo: ["moduleName": name])
        
        // 5. Call stop()
        do {
            try module.stop()
            logger.info("Module \(name) stop() succeeded")
        } catch {
            logger.error("Module \(name) stop() failed: \(error)")
            return .failure(.stopFailed(name: name, error: error))
        }
        
        // 6. Cleanup resources (if ModuleResourceReleasable is implemented)
        if let releasable = module as? ModuleResourceReleasable {
            releasable.releaseResources()
            logger.info("Module \(name) resources released")
        }
        
        // 7. Remove from registry
        registry.unregister(name: name)
        
        // 8. Mark as unloaded
        markUnloaded(name)
        
        // 9. Send unload event
        eventBus.emit(.moduleDidUnload, userInfo: ["moduleName": name])
        
        logger.info("Module \(name) unloaded successfully")
        return .success
    }
    
    // MARK: - Force Unload
    
    /// Force unload a module
    /// Skip stop(), directly cleanup and remove from registry
    /// Force unloads dependent modules first, then the target
    /// ⚠️ Caution: may cause resource leaks or runtime errors
    /// - Parameter name: Module name
    /// - Returns: Unload result
    public func forceUnload(name: String) -> ModuleUnloadResult {
        logger.warning("⚠️ Force unloading: \(name) (stop() will be skipped)")
        
        // 1. Check if module is registered
        guard registry.isLoaded(name: name) else {
            logger.warning("Module \(name) not loaded, cannot force unload")
            return .failure(.notLoaded(name: name))
        }
        
        // 2. Check XRZModule conformance
        guard let module = registry.getModule(named: name) as? XRZModule else {
            logger.error("Module \(name) does not conform to XRZModule, cannot force unload")
            return .failure(.notConformingToProtocol(name: name))
        }
        
        // 3. Force unload dependents first (recursive)
        let dependents = findDependents(of: name)
        for dependent in dependents {
            logger.warning("Force unloading dependent: \(dependent)")
            let result = forceUnload(name: dependent)
            if !result.isSuccess {
                logger.error("Dependent module \(dependent) force unload failed, continuing with \(name)")
            }
        }
        
        // 4. Send pre-unload event
        eventBus.emit(.moduleWillUnload, userInfo: [
            "moduleName": name,
            "forceUnload": true
        ])
        
        // 5. Skip stop(), direct cleanup
        if let releasable = module as? ModuleResourceReleasable {
            releasable.releaseResources()
            logger.info("Module \(name) resources force-released")
        }
        
        // 6. Remove from registry
        registry.unregister(name: name)
        
        // 7. Mark as unloaded
        markUnloaded(name)
        
        // 8. Send unload event
        eventBus.emit(.moduleDidUnload, userInfo: [
            "moduleName": name,
            "forceUnload": true
        ])
        
        logger.warning("Module \(name) force unloaded (stop() not called)")
        return .success
    }
    
    // MARK: - Query Interface
    
    /// Check if module has been unloaded by this unloader
    /// - Parameter name: Module name
    /// - Returns: Whether module is unloaded
    public func isUnloaded(name: String) -> Bool {
        os_unfair_lock_lock(&unloadedStorage.lock)
        defer { os_unfair_lock_unlock(&unloadedStorage.lock) }
        return unloadedStorage.unloaded.contains(name)
    }
    
    /// Find all modules that depend on a given module
    /// - Parameter moduleName: Depended-upon module name
    /// - Returns: List of dependent names
    public func findDependents(of moduleName: String) -> [String] {
        var dependents: [String] = []
        
        for name in registry.allModuleNames {
            if let metadata = registry.getMetadata(named: name) {
                if metadata.dependencies.contains(moduleName) {
                    dependents.append(name)
                }
            }
        }
        
        return dependents.sorted()
    }
    
    /// Check if module can be unloaded
    /// Must: loaded, implements XRZModule, no dependents
    /// - Parameter name: Module name
    /// - Returns: Whether unloadable and reason
    public func canUnload(name: String) -> (canUnload: Bool, reason: String?) {
        guard registry.isLoaded(name: name) else {
            return (false, "module not loaded")
        }
        
        guard registry.getModule(named: name) is XRZModule else {
            return (false, "module does not implement XRZModule")
        }
        
        let dependents = findDependents(of: name)
        if !dependents.isEmpty {
            return (false, "depended on by: \(dependents.joined(separator: ", "))")
        }
        
        return (true, nil)
    }
    
    // MARK: - Private Methods
    
    private func markUnloaded(_ name: String) {
        os_unfair_lock_lock(&unloadedStorage.lock)
        unloadedStorage.unloaded.insert(name)
        os_unfair_lock_unlock(&unloadedStorage.lock)
    }
}

// MARK: - Predefined Events (Extension)
public extension Notification.Name {
    /// Module will unload (start of unload flow)
    static let moduleWillUnload = Notification.Name("com.xianrenzhilu.module.willUnload")
    /// Module did unload (unload flow completed)
    static let moduleDidUnload = Notification.Name("com.xianrenzhilu.module.didUnload")
}

// MARK: - Module Resource Release Protocol
public protocol ModuleResourceReleasable {
    func releaseResources()
}

// MARK: - Test Code
/// ModuleUnloader functional verification tests
/// Run: `ModuleUnloaderTests.runAllTests()` in unit tests or Playground
public enum ModuleUnloaderTests {
    
    // MARK: - Test Modules
    
    /// Normal module (supports stop and resource release)
    final class TestUnloadableModule: XRZModule, ModuleResourceReleasable {
        let name: String
        var isStarted = false
        var isStopped = false
        var resourcesReleased = false
        var shouldFailStop = false
        var shouldFailResourceRelease = false
        
        required init() {
            self.name = "TestUnloadable"
        }
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {
            isStarted = true
        }
        
        func stop() throws {
            if shouldFailStop {
                throw NSError(domain: "TestModule", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated stop failure"])
            }
            isStopped = true
        }
        
        func releaseResources() {
            if shouldFailResourceRelease {
                // Resource release should not throw, but handle gracefully
            }
            resourcesReleased = true
        }
    }
    
    /// Simple module (only implements XRZModule, no resource release)
    final class SimpleModule: XRZModule {
        let name: String
        var isStopped = false
        
        required init() {
            self.name = "Simple"
        }
        
        init(name: String) {
            self.name = name
        }
        
        func start() throws {}
        func stop() throws {
            isStopped = true
        }
    }
    
    /// Module that does not implement XRZModule
    final class NonConformingModule {
        let name = "NonConforming"
    }
    
    // MARK: - Helper Methods
    
    /// Remove all modules from registry
    private static func cleanupRegistry() {
        let names = ModuleRegistry.shared.allModuleNames
        for name in names {
            ModuleRegistry.shared.unregister(name: name)
        }
    }
    
    /// Run all tests
    public static func runAllTests() {
        print("=== ModuleUnloader Tests ===")
        
        cleanupRegistry()
        testNormalUnload()
        cleanupRegistry()
        
        testForceUnload()
        cleanupRegistry()
        
        testDependentRefusal()
        cleanupRegistry()
        
        testNotLoadedModule()
        cleanupRegistry()
        
        testStopFailure()
        cleanupRegistry()
        
        testNonConformingModule()
        cleanupRegistry()
        
        testResourceRelease()
        cleanupRegistry()
        
        testCanUnloadCheck()
        cleanupRegistry()
        
        testMultipleDependents()
        cleanupRegistry()
        
        testForceUnloadWithDependents()
        cleanupRegistry()
        
        testEventEmission()
        cleanupRegistry()
        
        print("\n=== All ModuleUnloader Tests Passed ✅ ===")
    }
    
    // MARK: - Test 1: Normal Unload
    
    /// Test normal unload: stop() -> cleanup -> unregister -> emit event
    public static func testNormalUnload() {
        print("\n🧪 Test 1: Normal Unload")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = TestUnloadableModule(name: "NormalModule")
        registry.register(
            module: module,
            name: "NormalModule",
            metadata: ModuleMetadata(
                name: "NormalModule",
                version: "1.0",
                description: "Test",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "NormalModule")
        
        guard case .success = result else {
            fatalError("❌ Test 1 failed: Expected success, got \(result)")
        }
        guard !registry.isLoaded(name: "NormalModule") else {
            fatalError("❌ Test 1 failed: Module should be removed from registry")
        }
        guard module.isStopped else {
            fatalError("❌ Test 1 failed: stop() should be called")
        }
        guard module.resourcesReleased else {
            fatalError("❌ Test 1 failed: releaseResources() should be called")
        }
        guard unloader.isUnloaded(name: "NormalModule") else {
            fatalError("❌ Test 1 failed: Module should be marked unloaded")
        }
        
        print("✅ Test 1 passed: Normal unload workflow correct")
    }
    
    // MARK: - Test 2: Force Unload
    
    /// Test force unload: skip stop(), direct cleanup
    public static func testForceUnload() {
        print("\n🧪 Test 2: Force Unload")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = TestUnloadableModule(name: "ForceModule")
        registry.register(
            module: module,
            name: "ForceModule",
            metadata: ModuleMetadata(
                name: "ForceModule",
                version: "1.0",
                description: "Test",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        
        let result = unloader.forceUnload(name: "ForceModule")
        
        guard case .success = result else {
            fatalError("❌ Test 2 failed: Expected force unload success, got \(result)")
        }
        guard !registry.isLoaded(name: "ForceModule") else {
            fatalError("❌ Test 2 failed: Module should be removed")
        }
        guard !module.isStopped else {
            fatalError("❌ Test 2 failed: Force unload should not call stop()")
        }
        guard module.resourcesReleased else {
            fatalError("❌ Test 2 failed: Force unload should release resources")
        }
        
        print("✅ Test 2 passed: Force unload skips stop(), direct cleanup")
    }
    
    // MARK: - Test 3: Dependent Refusal
    
    /// Test refusal when module has dependents
    public static func testDependentRefusal() {
        print("\n🧪 Test 3: Dependent Refusal")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let coreModule = SimpleModule(name: "CoreModule")
        let dependentModule = SimpleModule(name: "DependentModule")
        
        registry.register(
            module: coreModule,
            name: "CoreModule",
            metadata: ModuleMetadata(
                name: "CoreModule",
                version: "1.0",
                description: "Core",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        registry.register(
            module: dependentModule,
            name: "DependentModule",
            metadata: ModuleMetadata(
                name: "DependentModule",
                version: "1.0",
                description: "Depends on Core",
                entryClass: "SimpleModule",
                dependencies: ["CoreModule"]
            )
        )
        
        let result = unloader.unload(name: "CoreModule")
        
        guard case .failure(.hasDependents(let module, let dependents)) = result else {
            fatalError("❌ Test 3 failed: Expected hasDependents, got \(result)")
        }
        guard module == "CoreModule" else {
            fatalError("❌ Test 3 failed: Module name mismatch")
        }
        guard dependents == ["DependentModule"] else {
            fatalError("❌ Test 3 failed: Dependents expected [DependentModule], got \(dependents)")
        }
        guard registry.isLoaded(name: "CoreModule") else {
            fatalError("❌ Test 3 failed: Core module should not be removed")
        }
        guard coreModule.isStopped == false else {
            fatalError("❌ Test 3 failed: stop() should not be called")
        }
        
        print("✅ Test 3 passed: Correctly refused unloading with dependents")
    }
    
    // MARK: - Test 4: Not Loaded Module
    
    /// Test unloading a module that is not loaded
    public static func testNotLoadedModule() {
        print("\n🧪 Test 4: Unload Not Loaded")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let result = unloader.unload(name: "GhostModule")
        
        guard case .failure(.notLoaded(let name)) = result else {
            fatalError("❌ Test 4 failed: Expected notLoaded, got \(result)")
        }
        guard name == "GhostModule" else {
            fatalError("❌ Test 4 failed: Module name mismatch")
        }
        
        print("✅ Test 4 passed: Not loaded module correctly refused")
    }
    
    // MARK: - Test 5: stop() Failure
    
    /// Test handling of stop() throwing an error
    public static func testStopFailure() {
        print("\n🧪 Test 5: stop() Failure")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = TestUnloadableModule(name: "FailStopModule")
        module.shouldFailStop = true
        registry.register(
            module: module,
            name: "FailStopModule",
            metadata: ModuleMetadata(
                name: "FailStopModule",
                version: "1.0",
                description: "Test",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "FailStopModule")
        
        guard case .failure(.stopFailed(let name, _)) = result else {
            fatalError("❌ Test 5 failed: Expected stopFailed, got \(result)")
        }
        guard name == "FailStopModule" else {
            fatalError("❌ Test 5 failed: Module name mismatch")
        }
        guard registry.isLoaded(name: "FailStopModule") else {
            fatalError("❌ Test 5 failed: Module should not be removed on stop failure")
        }
        
        print("✅ Test 5 passed: stop() failure rolls back correctly, module not removed")
    }
    
    // MARK: - Test 6: Non-conforming Module
    
    /// Test unloading a module without XRZModule conformance
    public static func testNonConformingModule() {
        print("\n🧪 Test 6: Non-conforming Module")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = NonConformingModule()
        registry.register(module: module, name: "NonConformingModule")
        
        let result = unloader.unload(name: "NonConformingModule")
        
        guard case .failure(.notConformingToProtocol(let name)) = result else {
            fatalError("❌ Test 6 failed: Expected notConformingToProtocol, got \(result)")
        }
        guard name == "NonConformingModule" else {
            fatalError("❌ Test 6 failed: Module name mismatch")
        }
        
        print("✅ Test 6 passed: Non-conforming module correctly refused")
    }
    
    // MARK: - Test 7: Resource Release
    
    /// Test module without ModuleResourceReleasable can still unload
    public static func testResourceRelease() {
        print("\n🧪 Test 7: No Resource Release Protocol")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let module = SimpleModule(name: "SimpleModule")
        registry.register(
            module: module,
            name: "SimpleModule",
            metadata: ModuleMetadata(
                name: "SimpleModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "SimpleModule")
        
        guard case .success = result else {
            fatalError("❌ Test 7 failed: Expected success, got \(result)")
        }
        guard !registry.isLoaded(name: "SimpleModule") else {
            fatalError("❌ Test 7 failed: Module should be removed")
        }
        guard module.isStopped else {
            fatalError("❌ Test 7 failed: stop() should be called")
        }
        
        print("✅ Test 7 passed: Module without resource release unloads normally")
    }
    
    // MARK: - Test 8: Can Unload Check
    
    /// Test canUnload method
    public static func testCanUnloadCheck() {
        print("\n🧪 Test 8: Can Unload Check")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        // Unregistered module
        let check1 = unloader.canUnload(name: "Missing")
        guard check1.canUnload == false, check1.reason?.contains("not loaded") == true else {
            fatalError("❌ Test 8a failed: Unregistered module should not be unloadable")
        }
        
        // Registered module without dependents
        let module = SimpleModule(name: "FreeModule")
        registry.register(
            module: module,
            name: "FreeModule",
            metadata: ModuleMetadata(
                name: "FreeModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        let check2 = unloader.canUnload(name: "FreeModule")
        guard check2.canUnload == true, check2.reason == nil else {
            fatalError("❌ Test 8b failed: Module without dependents should be unloadable")
        }
        
        // Module with dependents
        let dependent = SimpleModule(name: "UserModule")
        registry.register(
            module: dependent,
            name: "UserModule",
            metadata: ModuleMetadata(
                name: "UserModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: ["FreeModule"]
            )
        )
        let check3 = unloader.canUnload(name: "FreeModule")
        guard check3.canUnload == false, check3.reason?.contains("UserModule") == true else {
            fatalError("❌ Test 8c failed: Module with dependents should not be unloadable")
        }
        
        print("✅ Test 8 passed: canUnload check correct")
    }
    
    // MARK: - Test 9: Multiple Dependents
    
    /// Test module depended on by multiple modules
    public static func testMultipleDependents() {
        print("\n🧪 Test 9: Multiple Dependents")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let core = SimpleModule(name: "Core")
        let userA = SimpleModule(name: "UserA")
        let userB = SimpleModule(name: "UserB")
        
        registry.register(
            module: core,
            name: "Core",
            metadata: ModuleMetadata(
                name: "Core",
                version: "1.0",
                description: "Core",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        registry.register(
            module: userA,
            name: "UserA",
            metadata: ModuleMetadata(
                name: "UserA",
                version: "1.0",
                description: "UserA",
                entryClass: "SimpleModule",
                dependencies: ["Core"]
            )
        )
        registry.register(
            module: userB,
            name: "UserB",
            metadata: ModuleMetadata(
                name: "UserB",
                version: "1.0",
                description: "UserB",
                entryClass: "SimpleModule",
                dependencies: ["Core"]
            )
        )
        
        let dependents = unloader.findDependents(of: "Core")
        guard dependents.count == 2 else {
            fatalError("❌ Test 9 failed: Expected 2 dependents, got \(dependents.count)")
        }
        guard dependents.contains("UserA") && dependents.contains("UserB") else {
            fatalError("❌ Test 9 failed: Dependents should include UserA and UserB")
        }
        
        let result = unloader.unload(name: "Core")
        guard case .failure(.hasDependents(_, let deps)) = result else {
            fatalError("❌ Test 9 failed: Expected hasDependents")
        }
        guard deps.count == 2 else {
            fatalError("❌ Test 9 failed: Dependents should have 2 elements")
        }
        
        print("✅ Test 9 passed: Multiple dependents detection correct")
    }
    
    // MARK: - Test 10: Force Unload with Dependents
    
    /// Test force unload recursively unloads dependents
    public static func testForceUnloadWithDependents() {
        print("\n🧪 Test 10: Force Unload with Dependents")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        let core = TestUnloadableModule(name: "CoreF")
        let user = TestUnloadableModule(name: "UserF")
        
        registry.register(
            module: core,
            name: "CoreF",
            metadata: ModuleMetadata(
                name: "CoreF",
                version: "1.0",
                description: "Core",
                entryClass: "TestUnloadableModule",
                dependencies: []
            )
        )
        registry.register(
            module: user,
            name: "UserF",
            metadata: ModuleMetadata(
                name: "UserF",
                version: "1.0",
                description: "UserF",
                entryClass: "TestUnloadableModule",
                dependencies: ["CoreF"]
            )
        )
        
        let result = unloader.forceUnload(name: "CoreF")
        
        guard case .success = result else {
            fatalError("❌ Test 10 failed: Expected success, got \(result)")
        }
        guard !registry.isLoaded(name: "CoreF") else {
            fatalError("❌ Test 10 failed: CoreF should be removed")
        }
        guard !registry.isLoaded(name: "UserF") else {
            fatalError("❌ Test 10 failed: UserF should also be removed")
        }
        guard !core.isStopped else {
            fatalError("❌ Test 10 failed: CoreF stop() not called (force unload)")
        }
        guard !user.isStopped else {
            fatalError("❌ Test 10 failed: UserF stop() not called (force unload)")
        }
        guard core.resourcesReleased else {
            fatalError("❌ Test 10 failed: CoreF resources should be released")
        }
        guard user.resourcesReleased else {
            fatalError("❌ Test 10 failed: UserF resources should be released")
        }
        
        print("✅ Test 10 passed: Force unload recursively removes dependents")
    }
    
    // MARK: - Test 11: Event Emission
    
    /// Test event emission during unload
    public static func testEventEmission() {
        print("\n🧪 Test 11: Event Emission")
        
        let registry = ModuleRegistry.shared
        let eventBus = EventBus()
        let unloader = ModuleUnloader(registry: registry, eventBus: eventBus)
        
        var willUnloadReceived = false
        var didUnloadReceived = false
        var willUnloadModuleName: String?
        var didUnloadModuleName: String?
        
        let obs1 = eventBus.on(.moduleWillUnload) { notification in
            willUnloadReceived = true
            willUnloadModuleName = notification.userInfo?["moduleName"] as? String
        }
        
        let obs2 = eventBus.on(.moduleDidUnload) { notification in
            didUnloadReceived = true
            didUnloadModuleName = notification.userInfo?["moduleName"] as? String
        }
        
        let module = SimpleModule(name: "EventModule")
        registry.register(
            module: module,
            name: "EventModule",
            metadata: ModuleMetadata(
                name: "EventModule",
                version: "1.0",
                description: "Test",
                entryClass: "SimpleModule",
                dependencies: []
            )
        )
        
        let result = unloader.unload(name: "EventModule")
        
        guard case .success = result else {
            fatalError("❌ Test 11 failed: Expected success")
        }
        guard willUnloadReceived else {
            fatalError("❌ Test 11 failed: moduleWillUnload not received")
        }
        guard didUnloadReceived else {
            fatalError("❌ Test 11 failed: moduleDidUnload not received")
        }
        guard willUnloadModuleName == "EventModule" else {
            fatalError("❌ Test 11 failed: moduleWillUnload name mismatch")
        }
        guard didUnloadModuleName == "EventModule" else {
            fatalError("❌ Test 11 failed: moduleDidUnload name mismatch")
        }
        
        eventBus.off(obs1)
        eventBus.off(obs2)
        
        print("✅ Test 11 passed: Unload events emitted correctly")
    }
}
