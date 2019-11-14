pragma solidity ^0.5.2;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/drafts/SignedSafeMath.sol";

import "../Core/Core.sol";
import "../Core/SignedMath.sol";
import "./IEngine.sol";
import "./STF.sol";
import "./POF.sol";


/**
 * @title the stateless component for a PAM contract
 * implements the STF and POF of the Actus standard for a PAM contract
 * @dev all numbers except unix timestamp are represented as multiple of 10 ** 18
 * inputs have to be multiplied by 10 ** 18, outputs have to divided by 10 ** 18
 */
contract PAMEngine is Core, IEngine, STF, POF {

	/**
	 * initialize contract state space based on the contract terms
	 * @dev see initStateSpace()
	 * @param terms terms of the contract
	 * @return initial contract state
	 */
	function computeInitialState(LifecycleTerms memory terms)
		public
		pure
		returns (State memory)
	{
		State memory state;

		state.contractPerformance = ContractPerformance.PF;
		state.notionalScalingMultiplier = int256(1 * 10 ** PRECISION);
		state.interestScalingMultiplier = int256(1 * 10 ** PRECISION);
		state.lastEventTime = terms.statusDate;
		state.notionalPrincipal = terms.notionalPrincipal;
		state.nominalInterestRate = terms.nominalInterestRate;
		state.accruedInterest = terms.accruedInterest;
		state.feeAccrued = terms.feeAccrued;

		return state;
	}

	/**
	 * applys a prototype event to the current state of a contract and
	 * returns the contrat event and the new contract state
	 * @param terms terms of the contract
	 * @param state current state of the contract
	 * @param protoEvent prototype event to be evaluated and applied to the contract state
	 * @param currentTimestamp current timestamp
	 * @return the new contract state and the evaluated event
	 */
	function computeStateForProtoEvent(
		LifecycleTerms memory terms,
		State memory state,
		bytes32 protoEvent,
		uint256 currentTimestamp
	)
		public
		pure
		returns (State memory)
	{
		return stateTransitionFunction(
			protoEvent,
			state,
			terms,
			currentTimestamp
		);
	}

	/**
	 * applys a prototype event to the current state of a contract and
	 * returns the contrat event and the new contract state
	 * @param terms terms of the contract
	 * @param state current state of the contract
	 * @param protoEvent prototype event to be evaluated and applied to the contract state
	 * @param currentTimestamp current timestamp
	 * @return the new contract state and the evaluated event
	 */
	function computePayoffForProtoEvent(
		LifecycleTerms memory terms,
		State memory state,
		bytes32 protoEvent,
		uint256 currentTimestamp
	)
		public
		pure
		returns (int256)
	{
		return payoffFunction(
			protoEvent,
			state,
			terms,
			currentTimestamp
		);
	}

	/**
	 * computes a schedule segment of non-cyclic contract events based on the contract terms and the specified period
	 * @param terms terms of the contract
	 * @param segmentStart start timestamp of the segment
	 * @param segmentEnd end timestamp of the segement
	 * @return event schedule segment
	 */
	function computeNonCyclicProtoEventScheduleSegment(
		GeneratingTerms memory terms,
		uint256 segmentStart,
		uint256 segmentEnd
	)
		public
		pure
		returns (bytes32[MAX_EVENT_SCHEDULE_SIZE] memory)
	{
		bytes32[MAX_EVENT_SCHEDULE_SIZE] memory protoEventSchedule;
		uint16 index = 0;

		// initial exchange
		if (isInPeriod(terms.initialExchangeDate, segmentStart, segmentEnd)) {
			protoEventSchedule[index] = encodeProtoEvent(EventType.IED, terms.initialExchangeDate);
			index++;
		}

		// purchase
		if (terms.purchaseDate != 0) {
			if (isInPeriod(terms.purchaseDate, segmentStart, segmentEnd)) {
				protoEventSchedule[index] = encodeProtoEvent(EventType.PRD, terms.purchaseDate);
				index++;
			}
		}

		// termination
		if (terms.terminationDate != 0) {
			if (isInPeriod(terms.terminationDate, segmentStart, segmentEnd)) {
				protoEventSchedule[index] = encodeProtoEvent(EventType.TD, terms.terminationDate);
				index++;
			}
		}

		// principal redemption
		if (isInPeriod(terms.maturityDate, segmentStart, segmentEnd)) {
			protoEventSchedule[index] = encodeProtoEvent(EventType.MD, terms.maturityDate);
			index++;
		}

		return protoEventSchedule;
	}

	/**
	 * computes a schedule segment of cyclic contract events based on the contract terms and the specified period
	 * @param terms terms of the contract
	 * @param segmentStart start timestamp of the segment
	 * @param segmentEnd end timestamp of the segement
	 * @param eventType eventType of the cyclic schedule
	 * @return event schedule segment
	 */
	function computeCyclicProtoEventScheduleSegment(
		GeneratingTerms memory terms,
		uint256 segmentStart,
		uint256 segmentEnd,
		EventType eventType
	)
		public
		pure
		returns(bytes32[MAX_EVENT_SCHEDULE_SIZE] memory)
	{
		bytes32[MAX_EVENT_SCHEDULE_SIZE] memory protoEventSchedule;

		if (eventType == EventType.IP || eventType == EventType.IPCI) {
			uint256 index = 0;

			// interest payment related (e.g. for reoccurring interest payments)
			if (terms.nominalInterestRate != 0 && (
				terms.cycleOfInterestPayment.isSet == true && terms.cycleAnchorDateOfInterestPayment != 0)
			) {
				uint256[MAX_CYCLE_SIZE] memory interestPaymentSchedule = computeDatesFromCycleSegment(
					terms.cycleAnchorDateOfInterestPayment,
					terms.maturityDate,
					terms.cycleOfInterestPayment,
					terms.endOfMonthConvention,
					true,
					segmentStart,
					segmentEnd
				);
				if (terms.capitalizationEndDate != 0) {
					uint256 shiftedIPCITime = shiftEventTime(
						terms.capitalizationEndDate,
						terms.businessDayConvention,
						terms.calendar
					);
					if (isInPeriod(shiftedIPCITime, segmentStart, segmentEnd)) {
						protoEventSchedule[index] = encodeProtoEvent(EventType.IPCI, terms.capitalizationEndDate);
						index++;
					}
				}
				for (uint8 i = 0; i < MAX_CYCLE_SIZE; i++) {
					if (interestPaymentSchedule[i] == 0) break;
					uint256 shiftedIPDate = shiftEventTime(
						interestPaymentSchedule[i],
						terms.businessDayConvention,
						terms.calendar
					);
					if (isInPeriod(shiftedIPDate, segmentStart, segmentEnd) == false) continue;
					if (
						terms.capitalizationEndDate != 0 &&
						interestPaymentSchedule[i] <= terms.capitalizationEndDate
					) {
						if (interestPaymentSchedule[i] == terms.capitalizationEndDate) continue;
						protoEventSchedule[index] = encodeProtoEvent(EventType.IPCI, interestPaymentSchedule[i]);
						index++;
					} else {
						protoEventSchedule[index] = encodeProtoEvent(EventType.IP, interestPaymentSchedule[i]);
						index++;
					}
				}
			}

			// capitalization end date
			else if (terms.capitalizationEndDate != 0) {
				uint256 shiftedIPCIDate = shiftEventTime(
					terms.capitalizationEndDate,
					terms.businessDayConvention,
					terms.calendar
				);
				if (isInPeriod(shiftedIPCIDate, segmentStart, segmentEnd)) {
					protoEventSchedule[index] = encodeProtoEvent(EventType.IPCI, terms.capitalizationEndDate);
					index++;
				}
			}
		}

		if (eventType == EventType.RR) {
			uint256 index = 0;

			// rate reset
			if (terms.cycleOfRateReset.isSet == true && terms.cycleAnchorDateOfRateReset != 0) {
				uint256[MAX_CYCLE_SIZE] memory rateResetSchedule = computeDatesFromCycleSegment(
					terms.cycleAnchorDateOfRateReset,
					terms.maturityDate,
					terms.cycleOfRateReset,
					terms.endOfMonthConvention,
					false,
					segmentStart,
					segmentEnd
				);
				for (uint8 i = 0; i < MAX_CYCLE_SIZE; i++) {
					if (rateResetSchedule[i] == 0) break;
					uint256 shiftedRRDate = shiftEventTime(
						rateResetSchedule[i],
						terms.businessDayConvention,
						terms.calendar
					);
					if (isInPeriod(shiftedRRDate, segmentStart, segmentEnd) == false) continue;
					protoEventSchedule[index] = encodeProtoEvent(EventType.RR, rateResetSchedule[i]);
					index++;
				}
			}
			// ... nextRateReset
		}

		if (eventType == EventType.FP) {
			uint256 index = 0;

			// fees
			if (terms.cycleOfFee.isSet == true && terms.cycleAnchorDateOfFee != 0) {
				uint256[MAX_CYCLE_SIZE] memory feeSchedule = computeDatesFromCycleSegment(
					terms.cycleAnchorDateOfFee,
					terms.maturityDate,
					terms.cycleOfFee,
					terms.endOfMonthConvention,
					true,
					segmentStart,
					segmentEnd
				);
				for (uint8 i = 0; i < MAX_CYCLE_SIZE; i++) {
					if (feeSchedule[i] == 0) break;
					uint256 shiftedFPDate = shiftEventTime(
						feeSchedule[i],
						terms.businessDayConvention,
						terms.calendar
					);
					if (isInPeriod(shiftedFPDate, segmentStart, segmentEnd) == false) continue;
					protoEventSchedule[index] = encodeProtoEvent(EventType.FP, feeSchedule[i]);
					index++;
				}
			}
		}

		if (eventType == EventType.SC) {
			uint256 index;

			// scaling
			if ((terms.scalingEffect != ScalingEffect._000 || terms.scalingEffect != ScalingEffect._00M)
				&& terms.cycleAnchorDateOfScalingIndex != 0
			) {
				uint256[MAX_CYCLE_SIZE] memory scalingSchedule = computeDatesFromCycleSegment(
					terms.cycleAnchorDateOfScalingIndex,
					terms.maturityDate,
					terms.cycleOfScalingIndex,
					terms.endOfMonthConvention,
					true,
					segmentStart,
					segmentEnd
				);
				for (uint8 i = 0; i < MAX_CYCLE_SIZE; i++) {
					if (scalingSchedule[i] == 0) break;
					uint256 shiftedSCDate = shiftEventTime(
						scalingSchedule[i],
						terms.businessDayConvention,
						terms.calendar
					);
					if (isInPeriod(shiftedSCDate, segmentStart, segmentEnd) == false) continue;
					protoEventSchedule[index] = encodeProtoEvent(EventType.SC, scalingSchedule[i]);
					index++;
				}
			}
		}

		// revert("PAMEngine.computeCyclicProtoEventScheduleSegment: UNKNOWN_CYCLIC_EVENT_TYPE");
		return protoEventSchedule;
	}

	/**
	 * computes the next contract state based on the contract terms, state and the event type
	 * @param protoEvent proto event for which to evaluate the next state for
	 * @param state current state of the contract
	 * @param terms terms of the contract
	 * @param currentTimestamp current timestamp
	 * @return next contract state
	 */
	function stateTransitionFunction(
		bytes32 protoEvent,
		State memory state,
		LifecycleTerms memory terms,
		uint256 currentTimestamp
	)
		private
		pure
		returns (State memory)
	{
		(EventType eventType, uint256 scheduleTime) = decodeProtoEvent(protoEvent);

		if (eventType == EventType.AD) return STF_PAM_AD(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.CD) return STF_PAM_CD(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.FP) return STF_PAM_FP(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.IED) return STF_PAM_IED(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.IPCI) return STF_PAM_IPCI(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.IP) return STF_PAM_IP(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.PP) return STF_PAM_PP(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.PRD) return STF_PAM_PRD(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.MD) return STF_PAM_PR(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.PY) return STF_PAM_PY(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.RRF) return STF_PAM_RRF(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.RR) return STF_PAM_RR(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.SC) return STF_PAM_SC(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.TD) return STF_PAM_TD(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.DEL)  return STF_PAM_DEL(scheduleTime, terms, state, currentTimestamp);

		revert("PAMEngine.stateTransitionFunction: ATTRIBUTE_NOT_FOUND");
	}

	/**
	 * calculates the payoff for the current time based on the contract terms,
	 * state and the event type
	 * @param protoEvent proto event for which to evaluate the payoff for
	 * @param state current state of the contract
	 * @param terms terms of the contract
	 * @param currentTimestamp current timestamp
	 * @return payoff
	 */
	function payoffFunction(
		bytes32 protoEvent,
		State memory state,
		LifecycleTerms memory terms,
		uint256 currentTimestamp
	)
		private
		pure
		returns (int256)
	{
		(EventType eventType, uint256 scheduleTime) = decodeProtoEvent(protoEvent);

		if (eventType == EventType.AD) return 0;
		if (eventType == EventType.CD) return 0;
		if (eventType == EventType.IPCI) return 0;
		if (eventType == EventType.RRF) return 0;
		if (eventType == EventType.RR) return 0;
		if (eventType == EventType.SC) return 0;
		if (eventType == EventType.DEL) return 0;
		if (eventType == EventType.FP) return POF_PAM_FP(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.IED) return POF_PAM_IED(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.IP) return POF_PAM_IP(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.PP) return POF_PAM_PP(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.PRD) return POF_PAM_PRD(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.MD) return POF_PAM_PR(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.PY) return POF_PAM_PY(scheduleTime, terms, state, currentTimestamp);
		if (eventType == EventType.TD) return POF_PAM_TD(scheduleTime, terms, state, currentTimestamp);

		revert("PAMEngine.payoffFunction: ATTRIBUTE_NOT_FOUND");
	}
}
