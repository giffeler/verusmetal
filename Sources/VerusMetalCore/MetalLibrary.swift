import Foundation
import Metal
import MachO

func embeddedMetalLibraryData() -> DispatchData? {
    for index in 0..<_dyld_image_count() {
        guard let header = _dyld_get_image_header(index) else { continue }
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        if let bytes = getsectiondata(header64, "__TEXT", "__metallib", &size), size > 0 {
            return DispatchData(bytes: UnsafeRawBufferPointer(start: bytes, count: Int(size)))
        }
    }
    return nil
}
