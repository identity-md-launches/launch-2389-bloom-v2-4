// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    MockToken,
    StakedBLOOM,
    StakedSIMD,
    StakedETH,
    BloomFactory,
    BloomTreasury,
    ERC20Farm,
    Farm
} from "./helpers/Fixtures.sol";
import {DeployCore} from "../script/DeployCore.s.sol";
import {DeployBLOOMFarm} from "../script/DeployBLOOMFarm.s.sol";
import {DeploySIMDFarm} from "../script/DeploySIMDFarm.s.sol";
import {DeployETHFarm} from "../script/DeployETHFarm.s.sol";
import {DeploymentInputs} from "../script/DeploymentInputs.sol";

contract DeploymentTest is Test {
    function testCoreScriptAssignsEveryPrivilegeToConfirmedRequesterAndDoesNotInitialize() public {
        vm.chainId(1);
        DeployCore script = new DeployCore();
        vm.prank(address(0xC011AB));
        (BloomTreasury t, BloomFactory r) = script.run();
        assertEq(t.owner(), DeploymentInputs.REQUESTER);
        assertEq(r.owner(), DeploymentInputs.REQUESTER);
        assertEq(t.pendingOwner(), address(0));
        assertEq(r.pendingOwner(), address(0));
        assertEq(t.registry(), address(0));
        assertEq(r.bloom(), address(0));
        assertEq(r.farmCount(), 0);
        assertEq(r.treasury(), address(t));
        _checkRuntime(address(t));
        _checkRuntime(address(r));
    }

    function testFarmScriptsTakeRealInputsAndNeverEnableDepositsOrEmissions() public {
        vm.chainId(1);
        (BloomTreasury t, BloomFactory r) = new DeployCore().run();
        // A local mock is used only by tests; no deployment plan binds this token on mainnet.
        MockToken token = new MockToken(18);
        vm.prank(DeploymentInputs.REQUESTER);
        r.bindBloom(address(token));
        StakedBLOOM b = new DeployBLOOMFarm().run(address(r), address(t), address(token), 18);
        StakedSIMD s = new DeploySIMDFarm().run(address(r), address(t), address(token));
        StakedETH e = new DeployETHFarm().run(address(r), address(t), address(token));
        _checkDormant(b);
        _checkDormant(s);
        _checkDormant(e);
        _checkRuntime(address(b));
        _checkRuntime(address(s));
        _checkRuntime(address(e));
    }

    function testAllApplicationConstructorsSucceedWithDependenciesAbsent() public {
        vm.chainId(1);
        address requester = DeploymentInputs.REQUESTER;
        // Deterministically named test-only addresses intentionally have no code.
        address registry = makeAddr("absent registry");
        address treasury = makeAddr("absent treasury");
        address futureToken = makeAddr("not yet deployed token");
        assertEq(futureToken.code.length, 0);
        BloomTreasury t = new BloomTreasury(requester);
        BloomFactory r = new BloomFactory(requester, treasury);
        StakedBLOOM b = new StakedBLOOM(requester, registry, treasury, futureToken, 18);
        StakedSIMD s = new StakedSIMD(requester, registry, treasury, futureToken);
        StakedETH e = new StakedETH(requester, registry, treasury, futureToken);
        assertEq(t.owner(), requester);
        assertEq(r.owner(), requester);
        _checkDormant(b);
        _checkDormant(s);
        _checkDormant(e);
    }

    function testScriptRejectsMissingBloomAndWrongChain() public {
        vm.chainId(10);
        DeployCore core = new DeployCore();
        vm.expectRevert("Ethereum mainnet only");
        core.run();
        vm.chainId(1);
        (BloomTreasury t, BloomFactory r) = core.run();
        DeploySIMDFarm s = new DeploySIMDFarm();
        vm.expectRevert("Real deployed dependencies required");
        s.run(address(r), address(t), address(0));
    }

    function testScriptRejectsWrongRequesterAndUnboundToken() public {
        vm.chainId(1);
        BloomTreasury t = new BloomTreasury(address(this));
        BloomFactory r = new BloomFactory(address(this), address(t));
        MockToken token = new MockToken(18);
        DeployBLOOMFarm b = new DeployBLOOMFarm();
        vm.expectRevert("Requester must own registry");
        b.run(address(r), address(t), address(token), 18);
        (t, r) = new DeployCore().run();
        vm.expectRevert("BLOOM not bound or mismatch");
        b.run(address(r), address(t), address(token), 18);
    }

    function _checkDormant(Farm f) internal view {
        assertEq(f.owner(), DeploymentInputs.REQUESTER);
        assertTrue(f.depositsPaused());
        assertFalse(f.active());
        assertFalse(f.epochRunning());
        assertEq(f.totalShares(), 0);
        assertEq(f.rewardReserve(), 0);
        assertEq(f.renouncedPowers(), 0);
        assertEq(f.pendingOwner(), address(0));
    }

    function _checkRuntime(address application) internal view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
