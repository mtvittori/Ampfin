import Foundation
import Testing
@testable import Ampfin

struct DRSyncTests {
    private let idA = "9872a7f84ccdf9b0a2b4c4a4cf655695"
    private let idB = "0f0e437d9178cb702c5f8b8b7c59998c"
    private let old = Date(timeIntervalSince1970: 1_700_000_000)
    private let new = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func identicalSidesUploadNothing() {
        let local = [idA: DRResult(value: 12.3, measured: old)]
        let plan = DRSyncPlanner.plan(local: local, remote: [idA: 123], remoteDate: new, forceUpload: false)
        #expect(plan.updates.isEmpty)
        #expect(plan.chunks == nil)
    }

    @Test func newerServerValueWinsAndNothingIsSentBack() {
        let local = [idA: DRResult(value: 10, measured: old)]
        let plan = DRSyncPlanner.plan(local: local, remote: [idA: 123, idB: 80], remoteDate: new, forceUpload: false)
        #expect(plan.updates[idA]?.value == 12.3)
        #expect(plan.updates[idB]?.value == 8)
        #expect(plan.chunks == nil)
    }

    @Test func localSongTheServerLacksIsUploaded() {
        let local = [idA: DRResult(value: 12.3, measured: new), idB: DRResult(value: 8, measured: new)]
        let plan = DRSyncPlanner.plan(local: local, remote: [idA: 123], remoteDate: old, forceUpload: false)
        let decoded = DRSyncCoding.decode(chunks: plan.chunks ?? [])
        #expect(decoded == [idA: 123, idB: 80])
    }

    @Test func idsThatCannotTravelDoNotForceAnUploadEachTime() {
        let local = [idA: DRResult(value: 12.3, measured: old), "not-a-jellyfin-id": DRResult(value: 9, measured: old)]
        let plan = DRSyncPlanner.plan(local: local, remote: [idA: 123], remoteDate: new, forceUpload: false)
        #expect(plan.chunks == nil)
    }
}
