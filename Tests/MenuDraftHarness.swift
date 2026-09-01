import Foundation

@main
struct MenuDraftHarness {
    @MainActor
    static func main() {
        let model = GuardianModel()
        model.refresh()
        let draftZone = model.networkZone == "dormitory" ? "teaching_office" : "dormitory"
        model.networkZone = draftZone
        model.refresh()

        guard model.networkZone == draftZone, model.settingsDirty else {
            fputs("unsaved menu settings were overwritten by refresh\n", stderr)
            exit(1)
        }
        print("menu draft refresh regression test passed")
    }
}
