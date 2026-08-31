import Foundation

@main
struct MenuDraftHarness {
    @MainActor
    static func main() {
        let model = GuardianModel()
        model.refresh()
        model.networkZone = "dormitory"
        model.refresh()

        guard model.networkZone == "dormitory", model.settingsDirty else {
            fputs("unsaved menu settings were overwritten by refresh\n", stderr)
            exit(1)
        }
        print("menu draft refresh regression test passed")
    }
}
