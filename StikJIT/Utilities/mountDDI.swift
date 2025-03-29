//
//  mountDDI.swift
//  StikJIT
//
//  Created by Stossy11 on 29/03/2025.
//

import Foundation

typealias IdevicePairingFile = OpaquePointer
typealias TcpProviderHandle = OpaquePointer
typealias CoreDeviceProxyHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias ImageMounterHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer

func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
    MountingProgress.shared.progressCallback(progress: progress, total: total, context: context)
}

func readFile(path: String) -> Data? {
    guard let file = fopen(path, "rb") else {
        perror("Failed to open file")
        return nil
    }
    
    fseek(file, 0, SEEK_END)
    let fileSize = ftell(file)
    fseek(file, 0, SEEK_SET)
    
    guard fileSize > 0 else {
        fclose(file)
        return nil
    }
    
    var buffer = Data(count: fileSize)
    buffer.withUnsafeMutableBytes { ptr in
        fread(ptr.baseAddress, 1, fileSize, file)
    }
    
    fclose(file)
    return buffer
}

func htons(_ value: UInt16) -> UInt16 {
    return CFSwapInt16HostToBig(value)
}

func isMounted() -> Bool {
    var addr = sockaddr_in()
    memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = htons(UInt16(LOCKDOWN_PORT))
    let sockaddrPointer = UnsafeRawPointer(&addr).bindMemory(to: sockaddr.self, capacity: 1)
    
    let pairingFilePath = URL.documentsDirectory.appendingPathComponent("pairingFile.plist").path
    
    guard inet_pton(AF_INET, "10.7.0.1", &addr.sin_addr) == 1 else {
        print("Invalid IP address")
        return false
    }

    // Read pairing file
    var pairingFile: IdevicePairingFile?
    let err = idevice_pairing_file_read(pairingFilePath, &pairingFile)
    if err != IdeviceSuccess {
        print("Failed to read pairing file: \(err)")
        return false
    }

    // Create TCP provider
    var provider: TcpProviderHandle?
    let providerError = idevice_tcp_provider_new(sockaddrPointer, pairingFile, "ImageMounterTest", &provider)
    if providerError != IdeviceSuccess {
        print("Failed to create TCP provider: \(providerError)")
        return false
    }

    // Connect to image mounter
    var client: ImageMounterHandle?
    let connectError = image_mounter_connect_tcp(provider, &client)
    if connectError != IdeviceSuccess {
        print("Failed to connect to image mounter: \(connectError)")
        return false
    }
    tcp_provider_free(provider)

    print("wow")
    
    var devices: UnsafeMutableRawPointer?
    var devicesLen: size_t = 0
    let listError = image_mounter_copy_devices(client, &devices, &devicesLen)
    if listError == IdeviceSuccess {
        let deviceList = devices?.assumingMemoryBound(to: plist_t.self)
        var devices: [String] = []
        for i in 0..<devicesLen {
            let device = deviceList?[i]
            var xmlData: UnsafeMutablePointer<CChar>?
            var xmlLength: Int32 = 0
            
            // Use libplist function to convert to XML
            plist_to_xml(device, &xmlData, &xmlLength)
            if let xml = xmlData {
                devices.append("\(xml)")
            }
            plist_mem_free(xmlData)
            plist_free(device)
        }

        image_mounter_free(client)
        return devices.count != 0
    } else {
        print("Failed to get device list: \(listError)")
        return false
    }
}

func mountPersonalDDI(deviceIP: String = "10.7.0.1", imagePath: String, trustcachePath: String, manifestPath: String, pairingFilePath: String) -> Bool {
    idevice_init_logger(Debug, Disabled, nil)
    
    print("Mounting \(imagePath) \(trustcachePath) \(manifestPath)")
    
    guard let image = readFile(path: imagePath),
          let trustcache = readFile(path: trustcachePath),
          let buildManifest = readFile(path: manifestPath) else {
        print("Failed to read one or more files")
        return false
    }
    
    var addr = sockaddr_in()
    memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = htons(UInt16(LOCKDOWN_PORT))
    let sockaddrPointer = UnsafeRawPointer(&addr).bindMemory(to: sockaddr.self, capacity: 1)
    
    guard inet_pton(AF_INET, deviceIP, &addr.sin_addr) == 1 else {
        print("Invalid IP address")
        return false
    }

    var pairingFile: IdevicePairingFile?
    let err = idevice_pairing_file_read(pairingFilePath.cString(using: .utf8), &pairingFile)
    if err != IdeviceSuccess {
        print("Failed to read pairing file: \(err)")
        return false
    }


    var provider: TcpProviderHandle?
    let providerError = idevice_tcp_provider_new(sockaddrPointer, pairingFile, "ImageMounterTest".cString(using: .utf8), &provider)
    if providerError != IdeviceSuccess {
        print("Failed to create TCP provider: \(providerError)")
        return false
    }
    
    
    var pairingFile2: IdevicePairingFile?
    let P2err = idevice_pairing_file_read(pairingFilePath.cString(using: .utf8), &pairingFile2)
    if P2err != IdeviceSuccess {
        print("Failed to read pairing file: \(err)")
        return false
    }
    
    var lockdownClient: LockdowndClientHandle?
    guard lockdownd_connect_tcp(provider, &lockdownClient) == IdeviceSuccess else {
        print("Failed to connect to lockdownd")
        return false
    }
    
    guard lockdownd_start_session(lockdownClient, pairingFile2) == IdeviceSuccess else {
        print("Failed to start session")
        return false
    }
    
    var uniqueChipIDPlist: plist_t?
    guard lockdownd_get_value(lockdownClient, "UniqueChipID".cString(using: .utf8), &uniqueChipIDPlist) == IdeviceSuccess else {
        print("Failed to get UniqueChipID")
        return false
    }
    
    var uniqueChipID: UInt64 = 0
    plist_get_uint_val(uniqueChipIDPlist, &uniqueChipID)
    plist_free(uniqueChipIDPlist)
    print(uniqueChipID)
    
    
    var mounterClient: ImageMounterHandle?
    guard image_mounter_connect_tcp(provider, &mounterClient) == IdeviceSuccess else {
        print("Failed to connect to image mounter")
        return false
    }
    
    let result = image.withUnsafeBytes { imagePtr in
        trustcache.withUnsafeBytes { trustcachePtr in
            buildManifest.withUnsafeBytes { manifestPtr in
                image_mounter_mount_personalized_tcp_with_callback(
                    mounterClient,
                    provider,
                    imagePtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    image.count,
                    trustcachePtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    trustcache.count,
                    manifestPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    buildManifest.count,
                    nil,
                    uniqueChipID,
                    progressCallback,
                    nil
                )
            }
        }
    }
    
    if result != IdeviceSuccess {
        print(result)
        print("Failed to mount personalized image")
        return false
    } else {
        print("Successfully mounted personalized image!")
        return true
    }
}
