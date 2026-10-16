import CoreAudio
import CoreGraphics
import Foundation

/// The keyboard's brightness and volume keys for external displays, which macOS can't change
/// itself: brightness goes to the display under the pointer, volume to the display's
/// speakers when the sound plays there. Called on the input thread for every media key:
/// true when the key is taken (it then doesn't reach macOS).
public enum DisplayKeys {
    /// A key press is a sixteenth, like macOS's own steps.
    private static let step = 100.0 / 16

    public static func handle(_ key: Int32, down: Bool, at location: CGPoint) -> Bool {
        switch key {
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
            var display: CGDirectDisplayID = 0, count: UInt32 = 0
            guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count == 1,
                  CGDisplayIsBuiltin(display) == 0, CGDisplayVendorNumber(display) != 0x610 // Apple's own displays: macOS does them
            else { return false }
            if down { DDC.shared.nudge(volume: false, by: key == 2 ? step : -step, on: display) }
            return true
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP / _DOWN, NX_KEYTYPE_MUTE
            guard let display = soundDisplay(at: location) else { return false }
            if down {
                if key == 7 { DDC.shared.set(.muteToggle, on: display) } else { DDC.shared.nudge(volume: true, by: key == 0 ? step : -step, on: display) }
            }
            return true
        default:
            return false
        }
    }

    /// The display playing the sound: the output is a display (HDMI, DisplayPort) whose volume
    /// macOS can't set. The one under the pointer if it's external, else the only external one.
    private static func soundDisplay(at location: CGPoint) -> CGDirectDisplayID? {
        guard let device = defaultOutput(), isDisplayAudio(device), !hasVolume(device) else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
        if let under = external.first(where: { CGDisplayBounds($0).contains(location) }) { return under }
        return external.count == 1 ? external[0] : nil
    }

    private static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isDisplayAudio(_ device: AudioObjectID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    }

    /// Whether macOS can set the device's volume, overall or on its first channel.
    private static func hasVolume(_ device: AudioObjectID) -> Bool {
        [kAudioObjectPropertyElementMain, 1].contains { element in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &address) && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
    }
}
