import XCTest
@testable import FTPKit

final class ParserTests: XCTestCase {
    func testMLSDFromProFTPD() {
        let text = """
        modify=19700101000001;perm=flcdmpe;type=cdir;unique=1BU40001;UNIX.group=0;UNIX.mode=0755;UNIX.owner=0; .
        modify=20250402121659;perm=flcdmpe;type=pdir;unique=1BU40002;UNIX.group=0;UNIX.mode=0755;UNIX.owner=0; ..
        modify=20260716173520;perm=adfrw;size=1059560;type=file;unique=1BU40003;UNIX.group=0;UNIX.mode=0755;UNIX.owner=0; MiSTer
        modify=20260716173454;perm=flcdmpe;type=dir;unique=1BU40004;UNIX.group=0;UNIX.mode=0755;UNIX.owner=0; games
        modify=20250503082334;perm=flcdmpe;type=dir;unique=1BU40005;UNIX.group=0;UNIX.mode=0755;UNIX.owner=0; _DOS Games
        modify=20260706080324;perm=adfrw;size=18222;type=file;unique=1BU40006;UNIX.group=0;UNIX.mode=0755;UNIX.owner=0; 한글 파일.ini

        """
        let items = FTPListParser.parseMLSD(text, directory: "/media/fat")
        XCTAssertEqual(items.map(\.name), ["MiSTer", "games", "_DOS Games", "한글 파일.ini"])
        XCTAssertEqual(items[0].size, 1_059_560)
        XCTAssertEqual(items[0].kind, .file)
        XCTAssertEqual(items[1].kind, .directory)
        XCTAssertNil(items[1].size)
        XCTAssertEqual(items[2].path, "/media/fat/_DOS Games")
        XCTAssertEqual(items[0].modified, Date(timeIntervalSince1970: 1_784_223_320))
    }

    func testMLSTFullPath() {
        let item = FTPListParser.parseMLSDLine("modify=19700101000001;perm=flcdmpe;type=dir; /media/fat", directory: "/media")
        XCTAssertEqual(item?.name, "fat")
        XCTAssertEqual(item?.path, "/media/fat")
        XCTAssertEqual(item?.kind, .directory)
    }

    func testUnixLIST() {
        let text = """
        drwxr-xr-x   2 root     root         4096 Jul 16 17:34 games
        -rwxr-xr-x   1 root     root      1059560 Jul 16  2026 MiSTer
        lrwxrwxrwx   1 root     root           10 Jan  1  1980 link name -> /media/fat
        -rw-r--r--   1 root     root           12 Mar  3 09:00 file  with  spaces.txt
        total 12
        """
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
        let items = FTPListParser.parseLIST(text, directory: "/media/fat", now: now)
        XCTAssertEqual(items.map(\.name), ["games", "MiSTer", "link name", "file  with  spaces.txt"])
        XCTAssertEqual(items[1].size, 1_059_560)
        XCTAssertEqual(items[2].kind, .link)
        XCTAssertEqual(items[3].path, "/media/fat/file  with  spaces.txt")
    }

    func testPassiveReplies() {
        XCTAssertEqual(FTPConnection.parseEPSV("Entering Extended Passive Mode (|||10520|)"), 10520)
        XCTAssertEqual(FTPConnection.parsePASV("Entering Passive Mode (192,168,1,11,41,24)"), 41 * 256 + 24)
        XCTAssertEqual(FTPConnection.parsePASV("Entering Passive Mode 192,168,1,11,200,10"), 200 * 256 + 10)
        XCTAssertNil(FTPConnection.parseEPSV("garbage"))
    }

    func testRemotePath() {
        XCTAssertEqual(RemotePath.join("/", "media"), "/media")
        XCTAssertEqual(RemotePath.join("/media/fat", "games"), "/media/fat/games")
        XCTAssertEqual(RemotePath.parent(of: "/media/fat/games"), "/media/fat")
        XCTAssertEqual(RemotePath.parent(of: "/media"), "/")
        XCTAssertEqual(RemotePath.normalize("/media//fat/./games/../saves/"), "/media/fat/saves")
        XCTAssertEqual(RemotePath.lastComponent("/media/fat/_DOS Games"), "_DOS Games")
    }

    func testSubnetHosts() {
        let subnet = LocalSubnet(interface: "en1", address: IPv4("192.168.1.8")!, prefixLength: 24)
        let hosts = subnet.hostsToScan()
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first?.description, "192.168.1.1")
        XCTAssertEqual(hosts.last?.description, "192.168.1.254")
        XCTAssertFalse(hosts.contains(IPv4("192.168.1.8")!))
        XCTAssertEqual(subnet.displayLabel, "192.168.1.0/24")

        let wide = LocalSubnet(interface: "en0", address: IPv4("10.0.5.20")!, prefixLength: 16)
        XCTAssertEqual(wide.hostsToScan().count, 253)
        XCTAssertTrue(IPv4("172.20.1.1")!.isPrivate)
        XCTAssertFalse(IPv4("100.72.57.14")!.isPrivate)
    }
}
