import Darwin
import Foundation
@testable import Shared
import XCTest

#if os(iOS) && !targetEnvironment(macCatalyst)
final class CameraRTSPServerLoopbackTests: XCTestCase {
    private func sendAll(_ text: String, to socketFD: Int32) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(socketFD, base.advanced(by: offset), buffer.count - offset, 0)
                if sent <= 0 { return }
                offset += sent
            }
        }
    }

    private func readUntil(
        socketFD: Int32,
        timeout: TimeInterval = 5,
        predicate: (Data) -> Bool
    ) -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = recv(socketFD, &buffer, buffer.count, Int32(MSG_DONTWAIT))
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if predicate(data) { return data }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return data
    }

    private func connect(port: UInt16) -> Int32 {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
            let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected == 0 { return fd }
            _ = Darwin.close(fd)
            Thread.sleep(forTimeInterval: 0.05)
        }
        return -1
    }

    func testRTSPReceivesInterleavedControlAndSendsKeyframeRTP() throws {
        let server = CameraRTSPServer()
        let port = UInt16.random(in: 40000 ... 49999)
        let originalPort = server.port
        server.port = Int(port)
        defer {
            server.setActive(false)
            server.port = originalPort
        }

        server.setActive(true)
        let fd = connect(port: port)
        XCTAssertGreaterThanOrEqual(fd, 0, "RTSP loopback listener never opened")
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }

        let uri = "rtsp://127.0.0.1:\(port)/camera"
        sendAll("OPTIONS \(uri) RTSP/1.0\r\nCSeq: 1\r\n\r\n", to: fd)
        let options = readUntil(socketFD: fd) {
            String(data: $0, encoding: .utf8)?.contains("CSeq: 1") == true
        }
        XCTAssertTrue(String(data: options, encoding: .utf8)?.contains("200 OK") == true)

        sendAll(
            "SETUP \(uri)/trackID=0 RTSP/1.0\r\nCSeq: 2\r\n" +
                "Transport: RTP/AVP/TCP;unicast;interleaved=2-3\r\n\r\n",
            to: fd
        )
        let setup = readUntil(socketFD: fd) {
            String(data: $0, encoding: .utf8)?.contains("CSeq: 2") == true
        }
        XCTAssertTrue(String(data: setup, encoding: .utf8)?.contains("interleaved=2-3") == true)

        // Send a complete RTCP receiver report and a text request together.
        // consumeRequests must skip the binary frame before parsing the RTSP request.
        var mixed = Data([0x24, 0x03, 0x00, 0x02, 0x01, 0x02])
        mixed.append(Data("GET_PARAMETER \(uri) RTSP/1.0\r\nCSeq: 3\r\n\r\n".utf8))
        mixed.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                _ = Darwin.send(fd, base, bytes.count, 0)
            }
        }
        let getParameter = readUntil(socketFD: fd) {
            String(data: $0, encoding: .utf8)?.contains("CSeq: 3") == true
        }
        XCTAssertTrue(String(data: getParameter, encoding: .utf8)?.contains("200 OK") == true)

        sendAll("PLAY \(uri) RTSP/1.0\r\nCSeq: 4\r\n\r\n", to: fd)
        let play = readUntil(socketFD: fd) {
            String(data: $0, encoding: .utf8)?.contains("CSeq: 4") == true
        }
        XCTAssertTrue(String(data: play, encoding: .utf8)?.contains("200 OK") == true)
        XCTAssertEqual(server.debugPlayingClientCount, 1)

        // SPS/PPS are prepended to the IDR frame; the encoded bytes cross
        // the production RTP send-completion callback on a real TCP connection.
        server.testBroadcast(
            nalUnits: [Data([0x65, 0x88, 0x84])],
            sps: Data([0x67, 0x42, 0xE0, 0x1F]),
            pps: Data([0x68, 0xCE, 0x06, 0xE2]),
            isKeyframe: true
        )
        let rtp = readUntil(socketFD: fd) {
            $0.range(of: Data([0x24, 0x02])) != nil
        }
        XCTAssertTrue(rtp.range(of: Data([0x24, 0x02])) != nil, "No interleaved RTP arrived")

        let deadline = Date().addingTimeInterval(3)
        while server.debugSendingClientCount != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(server.debugSendingClientCount, 0)
        XCTAssertEqual(server.debugStalledSendDisconnects, 0)
    }

    func testAVCCNALUnitsExtractsTwoLengthPrefixedFrames() {
        let bytes = Data([
            0, 0, 0, 4, 0x67, 0x42, 0xE0, 0x1F,
            0, 0, 0, 3, 0x65, 0x88, 0x84,
        ])

        XCTAssertEqual(
            CameraRTSPServer.nalUnits(from: bytes),
            [
                Data([0x67, 0x42, 0xE0, 0x1F]),
                Data([0x65, 0x88, 0x84]),
            ]
        )
    }

    func testAVCCNALUnitsRejectsZeroLengthAndTruncatedFrames() {
        XCTAssertTrue(CameraRTSPServer.nalUnits(from: Data([0, 0, 0, 0])).isEmpty)
        XCTAssertTrue(CameraRTSPServer.nalUnits(from: Data([0, 0, 0, 4, 0x65])).isEmpty)
        XCTAssertTrue(CameraRTSPServer.nalUnits(from: Data([0, 0, 0])).isEmpty)
    }
}
#endif
