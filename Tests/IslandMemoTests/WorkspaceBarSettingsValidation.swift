import Foundation
import Combine

@main
@MainActor
struct WorkspaceBarSettingsValidation {
    struct RestartExpectation: Codable {
        let featureOrder: [String]
        let categories: [MemoCategory]
        let legacyID: String
        let taskBytes: Data
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3,
              ["prepare", "restart"].contains(CommandLine.arguments[1]),
              AppEnvironment.isPreview,
              let suite = AppEnvironment.current.preferencesSuite else {
            fatalError("Use the runner with a dedicated synthetic preview directory")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        require(directory == AppEnvironment.dataDirectory, "Fixture and preview directories must match")
        let defaults = AppEnvironment.defaults
        let expectedURL = directory.appendingPathComponent("expected-settings.json")
        let tasksURL = directory.appendingPathComponent("synthetic-tasks.json")
        if CommandLine.arguments[1] == "restart" {
            let expected = try JSONDecoder().decode(RestartExpectation.self, from: Data(contentsOf: expectedURL))
            let store = AppSettingsStore()
            require(store.featureOrder.map(\.rawValue) == expected.featureOrder, "Top order survives a fresh process")
            require(store.memoCategories == expected.categories, "Category edits and order survive a fresh process")
            require(store.effectiveMemoCategoryID(for: nil) == expected.legacyID,
                    "Missing task category stays attached to the original, removed category across restart")
            require(store.memoCategoryName(for: nil) == "已删除分类", "Deleted legacy category is explicit")
            let restoredTaskBytes = try Data(contentsOf: tasksURL)
            require(restoredTaskBytes == expected.taskBytes, "Task fixture bytes remain unchanged")
            print("PASS: Fresh-process settings restore and immutable nil-category identity; task bytes unchanged")
            return
        }

        require(defaults.persistentDomain(forName: suite) == nil, "Prepare requires an unused isolated suite")
        for feature in AppSettingsStore.Feature.movableCases {
            let placement: AppSettingsStore.WorkspacePlacement
            switch feature {
            case .memo, .clipboard, .links: placement = .tab
            case .music: placement = .home
            default: placement = .hidden
            }
            defaults.set(placement.rawValue, forKey: "workspace-placement-\(feature.rawValue)")
        }
        let categories = [
            MemoCategory(id: "synthetic-legacy", name: "原默认", colorHex: "#0A84FF"),
            MemoCategory(id: "synthetic-daily", name: "日常", colorHex: "#30D978"),
            MemoCategory(id: "synthetic-ideas", name: "灵感", colorHex: "#FF9F0A"),
        ]
        defaults.set(try JSONEncoder().encode(categories), forKey: "memo-categories-v1")
        var seededOrder = AppSettingsStore.Feature.allCases
        seededOrder.removeAll { $0 == .settings }
        seededOrder.insert(.settings, at: 2)
        defaults.set(seededOrder.map(\.rawValue), forKey: "feature-order")
        let tasks = [
            TaskItem(title: "旧数据没有分类 ID"),
            TaskItem(title: "有明确分类 ID", categoryID: categories[1].id),
            TaskItem(title: "已移除分类", categoryID: "synthetic-deleted"),
        ]
        let taskBytes = try JSONEncoder().encode(tasks)
        try taskBytes.write(to: tasksURL, options: .atomic)
        let store = AppSettingsStore()
        require(store.effectiveMemoCategoryID(for: nil) == categories[0].id,
                "Migration captures the original first category before any drag")
        require(defaults.string(forKey: "memo-legacy-default-category-id-v1") == categories[0].id,
                "Legacy category identity is persisted independently")

        var featurePublications = 0
        var categoryPublications = 0
        let featureSubscription = store.$featureOrder.dropFirst().sink { _ in featurePublications += 1 }
        let categorySubscription = store.$memoCategories.dropFirst().sink { _ in categoryPublications += 1 }
        defer { featureSubscription.cancel(); categorySubscription.cancel() }

        let originalOrder = store.featureOrder
        let originalVisible = store.orderedVisibleFeatures.filter { $0 != .settings }
        require(originalVisible.contains(.home), "Fixture includes the movable Home tab")
        let reorderedVisible = Array(originalVisible.reversed())
        require(store.reorderVisibleFeatures(reorderedVisible), "Valid visible-tab permutation commits")
        require(store.orderedVisibleFeatures.filter { $0 != .settings } == reorderedVisible,
                "Displayed top order matches the proposed final drag order")
        for index in originalOrder.indices where !originalVisible.contains(originalOrder[index]) {
            require(store.featureOrder[index] == originalOrder[index], "Hidden features and Settings retain exact slots")
        }
        require(store.enabledFeatures == Set([.memo, .clipboard, .links, .home, .settings]),
                "Reordering does not change feature placement")
        let initialPreferenceSnapshot = defaults.persistentDomain(forName: suite)! as NSDictionary
        let initialPublicationCount = featurePublications
        require(!store.reorderVisibleFeatures(reorderedVisible), "An unchanged order is a no-op")
        require(!store.reorderVisibleFeatures(Array(reorderedVisible.dropLast())), "Missing feature is rejected")
        require(!store.reorderVisibleFeatures(reorderedVisible + [.settings]), "Settings is not accepted as a dragged member")
        var duplicateFeatures = reorderedVisible
        duplicateFeatures[0] = duplicateFeatures[1]
        require(!store.reorderVisibleFeatures(duplicateFeatures), "Duplicate feature is rejected")
        var hiddenFeatures = reorderedVisible
        hiddenFeatures[0] = .mirror
        require(!store.reorderVisibleFeatures(hiddenFeatures), "Hidden feature injection is rejected")
        require(initialPreferenceSnapshot.isEqual(to: defaults.persistentDomain(forName: suite)!),
                "Invalid and unchanged feature orders preserve preferences")
        require(featurePublications == initialPublicationCount, "Invalid and unchanged orders do not publish")

        store.setWorkspacePlacement(.links, placement: .hidden)
        require(!store.reorderVisibleFeatures(reorderedVisible), "Stale drag snapshot after visibility change is rejected")
        store.setWorkspacePlacement(.links, placement: .tab)
        require(store.featureOrder == originalOrder.map { feature in
            guard let index = originalVisible.firstIndex(of: feature) else { return feature }
            return reorderedVisible[index]
        }, "Hide/reveal retains the stored order")

        let reversedCategoryIDs = categories.reversed().map(\.id)
        require(store.reorderMemoCategories(reversedCategoryIDs), "Category can move exactly to the last position")
        require(store.memoCategories.map(\.id) == reversedCategoryIDs, "Exact category permutation commits")
        require(store.effectiveMemoCategoryID(for: nil) == categories[0].id && store.memoCategoryName(for: nil) == "原默认",
                "Category reorder does not reclassify or rename old nil-category tasks")
        require(store.effectiveMemoCategoryID(for: categories[1].id) == categories[1].id,
                "Explicit category remains explicit")
        require(store.effectiveMemoCategoryID(for: "synthetic-deleted") == "synthetic-deleted",
                "Unknown category remains unknown")
        require(store.memoCategoryName(for: "synthetic-deleted") == "已删除分类", "Unknown ID never takes the first name")
        let categorySnapshot = defaults.persistentDomain(forName: suite)! as NSDictionary
        let categoryPublicationCount = categoryPublications
        require(!store.reorderMemoCategories(reversedCategoryIDs), "Unchanged category order is a no-op")
        require(!store.reorderMemoCategories(Array(reversedCategoryIDs.dropLast())), "Missing category is rejected")
        require(!store.reorderMemoCategories(reversedCategoryIDs + ["synthetic-new"]), "New category injection is rejected")
        require(!store.reorderMemoCategories([categories[0].id, categories[0].id, categories[2].id]),
                "Duplicate category is rejected")
        require(!store.reorderMemoCategories([categories[0].id, categories[1].id, "synthetic-new"]),
                "Unknown same-count category is rejected")
        require(categorySnapshot.isEqual(to: defaults.persistentDomain(forName: suite)!),
                "Invalid and unchanged category orders preserve preferences")
        require(categoryPublications == categoryPublicationCount, "Rejected category changes do not publish")

        store.moveMemoCategory(categories[0].id, before: categories[2].id)
        require(store.effectiveMemoCategoryID(for: nil) == categories[0].id,
                "The existing settings drag API uses the same stable legacy semantics")
        store.addMemoCategory()
        require(store.memoCategories.count == 4, "A fourth category can be added")
        store.addMemoCategory()
        require(store.memoCategories.count == 4, "Existing four-category cap remains enforced")
        let renamed = store.memoCategories.first { $0.id == categories[1].id }!
        store.updateMemoCategory(renamed, name: "  改过的分类  ", colorHex: "#BF5AF2")
        require(store.memoCategoryName(for: renamed.id) == "改过的分类", "Names still trim and resolve by stable ID")
        store.removeMemoCategory(categories[0])
        require(store.effectiveMemoCategoryID(for: nil) == categories[0].id,
                "Deleting the old default does not assign old tasks elsewhere")
        require(store.memoCategoryName(for: nil) == "已删除分类", "Removed legacy default has an explicit label")
        require(store.effectiveMemoCategoryID(for: categories[0].id) == categories[0].id,
                "An explicitly removed category is not reassigned either")
        let withRemovedCategory = store.memoCategories
        store.resetMemoCategories()
        require(store.effectiveMemoCategoryID(for: nil) == categories[0].id,
                "Resetting visible categories does not reset legacy task identity")
        // Restore only this test suite's synthetic category collection before
        // saving the final order, so restart also checks custom-name persistence.
        defaults.set(try JSONEncoder().encode(withRemovedCategory), forKey: "memo-categories-v1")
        let restored = AppSettingsStore()
        require(restored.reorderMemoCategories(Array(restored.memoCategories.reversed().map(\.id))),
                "Custom category order can change after reloading settings")
        let finalTaskBytes = try Data(contentsOf: tasksURL)
        require(finalTaskBytes == taskBytes, "All settings operations leave task file bytes unchanged")
        let expected = RestartExpectation(featureOrder: restored.featureOrder.map(\.rawValue),
                                          categories: restored.memoCategories,
                                          legacyID: categories[0].id, taskBytes: taskBytes)
        try JSONEncoder().encode(expected).write(to: expectedURL, options: .atomic)
        require(defaults.synchronize(), "Isolated preferences synchronize before process exit")
        print("PASS: Exact stable-ID reorder, Home movement, hidden slots, invalid/no-op rejection, stale snapshots, category cap/edit/delete/reset and fixed legacy identity")
    }
}
