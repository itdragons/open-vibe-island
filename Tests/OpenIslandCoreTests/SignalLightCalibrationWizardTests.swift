import Foundation
import Testing
@testable import OpenIslandCore

struct SignalLightCalibrationWizardTests {
    @Test
    func startsOnTheFirstCandidatePin() {
        let wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3])
        #expect(wizard.currentPin == 1)
        #expect(wizard.isFinished == false)
        #expect(wizard.unresolvedColors == [.red, .yellow, .green])
    }

    @Test
    func finishesAsSoonAsAllThreeColorsAreIdentified() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3, 4, 5])
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)
        wizard.recordObservation(.green)

        #expect(wizard.isFinished)
        #expect(wizard.mapping == [.red: 1, .yellow: 2, .green: 3])
        #expect(wizard.unresolvedColors.isEmpty)
    }

    @Test
    func skipsPinsReportedAsNothing() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3, 4])
        wizard.recordObservation(.nothing)
        wizard.recordObservation(.red)

        #expect(wizard.mapping == [.red: 2])
        #expect(wizard.currentPin == 3)
    }

    @Test
    func finishesWithUnresolvedColorsWhenCandidatesRunOut() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2])
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)

        #expect(wizard.isFinished)
        #expect(wizard.mapping == [.red: 1, .yellow: 2])
        #expect(wizard.unresolvedColors == [.green])
    }

    @Test
    func ignoresARepeatedAnswerForAnAlreadyResolvedColor() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3, 4])
        wizard.recordObservation(.red)
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)
        wizard.recordObservation(.green)

        #expect(wizard.mapping == [.red: 1, .yellow: 3, .green: 4])
    }

    @Test
    func resetDiscardsAllRecordedAnswers() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3])
        wizard.recordObservation(.red)
        wizard.reset()

        #expect(wizard.currentPin == 1)
        #expect(wizard.mapping.isEmpty)
        #expect(wizard.isFinished == false)
    }

    @Test
    func doesNothingOnceFinished() {
        var wizard = SignalLightCalibrationWizard(candidatePins: [1, 2, 3])
        wizard.recordObservation(.red)
        wizard.recordObservation(.yellow)
        wizard.recordObservation(.green)
        let finishedMapping = wizard.mapping

        wizard.recordObservation(.red)

        #expect(wizard.mapping == finishedMapping)
    }
}
