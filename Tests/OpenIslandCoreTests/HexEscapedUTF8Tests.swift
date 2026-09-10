import Foundation
import Testing
@testable import OpenIslandCore

struct HexEscapedUTF8Tests {
    @Test
    func decodesPythonStyleUTF8PathSegment() {
        // UTF-8 for 診療報酬AI研究所
        let escaped =
            #"\xe8\xa8\xba\xe7\x99\x82\xe5\xa0\xb1\xe9\x85\xacAI\xe7\xa0\x94\xe7\xa9\xb6\xe6\x89\x80"#
        #expect(HexEscapedUTF8.decodeIfNeeded(escaped) == "診療報酬AI研究所")
    }

    @Test
    func decodesEscapedSegmentInsideAbsolutePath() {
        let escaped =
            #"/Users/me/Library/CloudStorage/Drive/\xe8\xa8\xba\xe7\x99\x82\xe5\xa0\xb1\xe9\x85\xacAI\xe7\xa0\x94\xe7\xa9\xb6\xe6\x89\x80"#
        #expect(
            HexEscapedUTF8.decodeIfNeeded(escaped)
                == "/Users/me/Library/CloudStorage/Drive/診療報酬AI研究所"
        )
    }

    @Test
    func stripsPythonBytesLiteralWrapper() {
        let wrapped =
            #"b'\xe8\xa8\xba\xe7\x99\x82\xe5\xa0\xb1\xe9\x85\xacAI\xe7\xa0\x94\xe7\xa9\xb6\xe6\x89\x80'"#
        #expect(HexEscapedUTF8.decodeIfNeeded(wrapped) == "診療報酬AI研究所")
    }

    @Test
    func leavesNormalPathsUnchanged() {
        let path = "/Users/me/Documents/open-island"
        #expect(HexEscapedUTF8.decodeIfNeeded(path) == path)
        #expect(HexEscapedUTF8.decodeIfNeeded("診療報酬") == "診療報酬")
    }

    @Test
    func workspaceNameUsesDecodedLastComponent() {
        let cwd =
            #"/Users/me/Drive/\xe8\xa8\xba\xe7\x99\x82\xe5\xa0\xb1\xe9\x85\xacAI\xe7\xa0\x94\xe7\xa9\xb6\xe6\x89\x80"#
        #expect(WorkspaceNameResolver.workspaceName(for: cwd) == "診療報酬AI研究所")
    }
}
