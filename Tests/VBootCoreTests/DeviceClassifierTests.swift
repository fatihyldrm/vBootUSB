import Testing
@testable import VBootCore

@Suite("Device classification — safety logic")
struct DeviceClassifierTests {

    @Test("A disk holding the root volume is always marked as the system disk")
    func rootIsSystemDisk() {
        let c = DeviceClassifier.classify(
            bsdName: "disk3",
            rootWholeDiskBSD: "disk3",
            isInternal: false,
            isRemovable: true,
            isEjectable: true
        )
        #expect(c == .systemDisk)
    }

    @Test("An internal disk is classified as not writable")
    func internalDiskProtected() {
        let c = DeviceClassifier.classify(
            bsdName: "disk0",
            rootWholeDiskBSD: "disk3",
            isInternal: true,
            isRemovable: false,
            isEjectable: false
        )
        #expect(c == .internalDisk)
    }

    @Test("A removable USB stick is treated as external/removable")
    func removableIsExternal() {
        let c = DeviceClassifier.classify(
            bsdName: "disk4",
            rootWholeDiskBSD: "disk3",
            isInternal: false,
            isRemovable: true,
            isEjectable: true
        )
        #expect(c == .externalRemovable)
    }

    @Test("An external fixed drive (USB SSD) becomes externalFixed and asks for extra confirmation")
    func externalFixed() {
        let c = DeviceClassifier.classify(
            bsdName: "disk5",
            rootWholeDiskBSD: "disk3",
            isInternal: false,
            isRemovable: false,
            isEjectable: false
        )
        #expect(c == .externalFixed)
    }

    @Test("Write eligibility: system and internal disks are never eligible")
    func writeEligibility() {
        let system = makeDevice(.systemDisk, writable: true)
        let internalD = makeDevice(.internalDisk, writable: true)
        let removable = makeDevice(.externalRemovable, writable: true)
        let fixed = makeDevice(.externalFixed, writable: true)
        let removableReadOnly = makeDevice(.externalRemovable, writable: false)

        #expect(system.isWriteEligible == false)
        #expect(internalD.isWriteEligible == false)
        #expect(removable.isWriteEligible == true)
        #expect(fixed.isWriteEligible == true)
        #expect(fixed.requiresExtraConfirmation == true)
        #expect(removableReadOnly.isWriteEligible == false)
    }

    private func makeDevice(_ classification: DeviceClassification, writable: Bool) -> StorageDevice {
        StorageDevice(
            bsdName: "disk9",
            devicePath: "/dev/disk9",
            rawDevicePath: "/dev/rdisk9",
            mediaName: "Test Media",
            vendor: "ACME",
            model: "USB Stick",
            sizeBytes: 32_000_000_000,
            isInternal: classification == .internalDisk,
            isRemovable: classification == .externalRemovable,
            isEjectable: classification == .externalRemovable,
            isWritable: writable,
            busProtocol: "USB",
            classification: classification
        )
    }
}

@Suite("Byte formatting")
struct ByteFormatTests {
    @Test("Base-1000 human-readable output")
    func humanize() {
        #expect(ByteFormat.humanize(512) == "512 B")
        #expect(ByteFormat.humanize(32_000_000_000) == "32.0 GB")
        #expect(ByteFormat.humanize(1_000_000) == "1.0 MB")
    }
}
