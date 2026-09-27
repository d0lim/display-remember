import Foundation

/// User-directed edits use the currently selected screen, even if its EDID is not unique.
/// The caller must revalidate the complete snapshot immediately before executing.
public enum ManualPlan {
    public static func arguments(displays: [DisplaySnapshot], displayID: UInt32,
                                 settings: DisplaySettings, mirrorPrimaryID: UInt32?,
                                 makeMain: Bool = false) throws -> [String] {
        let requested = try profile(displays: displays, displayID: displayID, settings: settings,
                                    mirrorPrimaryID: mirrorPrimaryID, makeMain: makeMain)
        return try ProfileMatcher.arguments(profile: requested, displays: temporaryIdentities(displays))
    }

    public static func profile(displays: [DisplaySnapshot], displayID: UInt32,
                               settings: DisplaySettings, mirrorPrimaryID: UInt32?,
                               makeMain: Bool = false) throws -> DisplayProfile {
        try ProfileValidation.inventory(displays)
        try ProfileValidation.settings(settings)
        guard let selected = displays.first(where: { $0.id == displayID }) else {
            throw DisplayRememberError("The selected display is no longer connected.")
        }
        if settings.enabled, let parent = selected.mirrorPrimaryID, parent == mirrorPrimaryID {
            var previous = selected.settings
            var requested = settings
            previous.modeNumber = nil
            requested.modeNumber = nil
            previous.quiet = false
            requested.quiet = false
            guard previous == requested, settings.modeNumber == nil else {
                throw DisplayRememberError("Change resolution, rotation and placement on the mirror source, or choose an extended display first.")
            }
        }
        var desired = displays
        for index in desired.indices {
            // Mode indices are transient; keep other screens at their semantic settings.
            desired[index].settings.modeNumber = nil
            if desired[index].id == displayID {
                desired[index].settings = settings
                desired[index].mirrorPrimaryID = settings.enabled ? mirrorPrimaryID : nil
            }
        }
        if makeMain {
            guard settings.enabled, mirrorPrimaryID == nil else {
                throw DisplayRememberError("The main display must be enabled and cannot be a mirror follower.")
            }
            for index in desired.indices {
                desired[index].settings.x -= settings.x
                desired[index].settings.y -= settings.y
            }
        }
        desired = temporaryIdentities(desired)
        var entries: [ProfileDisplay] = []
        for display in desired {
            let followers = desired.filter { $0.mirrorPrimaryID == display.id }.map { String($0.id) }
            entries.append(ProfileDisplay(key: String(display.id), label: display.name,
                match: DisplaySelector(vendor: 1, product: 1, serialText: "manual-\(display.id)"),
                settings: display.settings, mirrors: followers))
        }
        guard mirrorPrimaryID == nil || desired.contains(where: { $0.id == mirrorPrimaryID }) else {
            throw DisplayRememberError("The mirror source is no longer connected.")
        }
        let profile = DisplayProfile(name: "Manual edit", displays: entries)
        _ = try ProfileMatcher.arguments(profile: profile, displays: temporaryIdentities(displays))
        return profile
    }

    public static func matches(profile: DisplayProfile, displays: [DisplaySnapshot]) throws -> Bool {
        try ProfileMatcher.matches(profile: profile, displays: temporaryIdentities(displays))
    }

    private static func temporaryIdentities(_ displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        displays.map { original in
            var display = original
            display.identity = HardwareIdentity(vendor: 1, product: 1, serialText: "manual-\(display.id)")
            return display
        }
    }
}
