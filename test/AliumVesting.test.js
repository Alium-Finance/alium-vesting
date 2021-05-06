// eslint-disable-next-line no-unused-vars
const {
    BN,
    expectEvent,
    expectRevert,
    time,
    ether,
} = require('@openzeppelin/test-helpers');
const { assert } = require('chai');

const AliumVesting = artifacts.require('AliumVesting');
const ALM = artifacts.require('MockALM');
const AliumCash = artifacts.require('MockAliumCashbox');

contract('AliumVesting', (accounts) => {
    const OWNER = accounts[0];
    const HOLDER = accounts[1];
    const FREEZE_MASTER = accounts[2];
    const HACKER = accounts[3];

    let cashbox, vesting, aliumToken;

    let releaseTime;

    const ONE_DAY = 60 * 60 * 24;
    const ALM_TOTAL_SUPPLY = ether('250000000');

    beforeEach(async function () {
        aliumToken = await ALM.new();
        cashbox = await AliumCash.new();

        await cashbox.initialize(aliumToken.address, OWNER);

        releaseTime = new BN(await time.latest()).addn(100);

        vesting = await AliumVesting.new(
            aliumToken.address,
            cashbox.address,
            FREEZE_MASTER,
            releaseTime.toString(),
        );

        await vesting.addLockPlan(0, [ONE_DAY * 7, ONE_DAY * 14, ONE_DAY * 21], [33, 33, 34]);
        await vesting.addLockPlan(1, [ONE_DAY * 5, ONE_DAY * 10, ONE_DAY * 15, ONE_DAY * 20], [25, 25, 25, 25]);
        await vesting.addLockPlan(2, [ONE_DAY * 3, ONE_DAY * 6, ONE_DAY * 9, ONE_DAY * 12, ONE_DAY * 15], [20, 20, 20, 20, 20]);

        await aliumToken.transfer(HOLDER, ether('5000'));
        await aliumToken.transfer(HACKER, ether('5000'));
        await aliumToken.transfer(cashbox.address, ALM_TOTAL_SUPPLY.sub(ether('5000')).sub(ether('5000')));

        await cashbox.setWalletLimit(vesting.address, ALM_TOTAL_SUPPLY);
    });

    describe('All required tests', async function () {
        it('Should fail if freeze account without permissions', async function () {
            const b = await aliumToken.balanceOf(HOLDER);

            assert.equal(b.toString(10), ether('5000').toString(10));

            await expectRevert(
                vesting.freeze(HOLDER, ether('5000'), 1, { from: HOLDER }),
                'Vesting: caller is not the freezer');
            await expectRevert(
                vesting.freeze(HOLDER, ether('5000'), 1, { from: HACKER }),
                'Vesting: caller is not the freezer',
            );
        });

        it('Should returns valid unlock timestamps and amounts', async function () {
            const tokenAmount = 1000;
            const firstPlanUnlockOffset = ONE_DAY * 7;
            const secondPlanUnlockOffset = ONE_DAY * 5;
            const thirdPlanUnlockOffset = ONE_DAY * 3;

            let unlockResult0 = await vesting.getNextUnlockAt(0);
            let unlockResult1 = await vesting.getNextUnlockAt(1);
            let unlockResult2 = await vesting.getNextUnlockAt(2);

            assert.equal(unlockResult0.timestamp.toString(), releaseTime.addn(firstPlanUnlockOffset).toString());
            assert.equal(unlockResult1.timestamp.toString(), releaseTime.addn(secondPlanUnlockOffset).toString());
            assert.equal(unlockResult2.timestamp.toString(), releaseTime.addn(thirdPlanUnlockOffset).toString());

            assert.equal(unlockResult0.amount.toString(), 0);
            assert.equal(unlockResult1.amount.toString(), 0);
            assert.equal(unlockResult2.amount.toString(), 0);

            await vesting.freeze(HOLDER, tokenAmount, 0, { from: FREEZE_MASTER }); // freeze
            await vesting.freeze(HOLDER, tokenAmount, 1, { from: FREEZE_MASTER }); // freeze
            await vesting.freeze(HOLDER, tokenAmount, 2, { from: FREEZE_MASTER }); // freeze

            unlockResult0 = await vesting.getNextUnlockAt(0);
            unlockResult1 = await vesting.getNextUnlockAt(1);
            unlockResult2 = await vesting.getNextUnlockAt(2);

            assert.isAbove(unlockResult0.amount.toNumber(), 0);
            assert.isAbove(unlockResult1.amount.toNumber(), 0);
            assert.isAbove(unlockResult2.amount.toNumber(), 0);
            assert.isAbove(Number(await aliumToken.balanceOf(vesting.address)), 0);
        });

        it('Should success if freeze from freezer account', async function () {
            const planID = 1;

            const tx = await vesting.freeze(HOLDER, ether('9000'), planID, { from: FREEZE_MASTER }); // freeze 9000
            expectEvent.inLogs(tx.logs, 'TokensLocked');

            console.log('Gas used for freeze: %d', tx.receipt.gasUsed);

            const balance = await vesting.getBalanceOf(HOLDER, planID);

            assert.equal(balance.totalBalance.toString(), ether('9000').toString());
            assert.equal(balance.frozenBalance.toString(), ether('9000').toString());
            assert.equal(balance.withdrawnBalance.toString(), '0');
            assert.equal((await aliumToken.balanceOf(vesting.address)).toString(), ether('9000').toString());
        });

        it('Can get frozen balances with several consecutive locks', async function () {
            const tokenAmount = 8000;
            const planID = 2;

            await vesting.freeze(HOLDER, tokenAmount, planID, { from: FREEZE_MASTER });

            assert.equal((await vesting.getBalanceOf(HOLDER, planID)).frozenBalance.toString(), tokenAmount);

            const balancePendingBefore = await vesting.pendingReward(HOLDER, planID);
            await time.increaseTo(releaseTime.addn(100));

            assert.equal((await vesting.getBalanceOf(HOLDER, planID)).frozenBalance.toString(), tokenAmount);

            await time.increaseTo(releaseTime.add(time.duration.days(92)));

            const balancePendingAfter = await vesting.pendingReward(HOLDER, planID);

            assert.equal(balancePendingBefore.toString(), 0);
            assert.equal(balancePendingAfter.toString(), tokenAmount);
        });

        it('Should fail on exist plan update', async function () {
            await expectRevert(
                vesting.addLockPlan(0, [ONE_DAY * 7, ONE_DAY * 14, ONE_DAY * 21], [33, 33, 34]),
                'Vesting: plan update is not possible',
            );
        });

        it('Should success claim tokens from pool 3 after 100% freeze period', async function () {
            const tokenAmount = 100000000;
            const planID = 2;
            const thirdPlanUnlockOffset = ONE_DAY * 3;
            const allTimeOffset = ONE_DAY * 1000;

            await time.increase((await time.latest()).add(new BN(thirdPlanUnlockOffset)).addn(100));

            await vesting.freeze(HOLDER, tokenAmount, planID, { from: FREEZE_MASTER });
            await vesting.claim(planID, { from: HOLDER });

            assert.equal((await aliumToken.balanceOf(vesting.address)).toString(), 0);
 
            // check claim second time
            await vesting.freeze(HOLDER, 1000, planID, { from: FREEZE_MASTER });
            await vesting.claim(planID, { from: HOLDER });

            assert.equal((await aliumToken.balanceOf(vesting.address)).toString(), 0);
      
            // check claim all
            await time.increase((await time.latest()).add(new BN(allTimeOffset)).addn(100));

            await vesting.freeze(HOLDER, 1000, 0, { from: FREEZE_MASTER });
            await vesting.freeze(HOLDER, 2000, 1, { from: FREEZE_MASTER });
            await vesting.freeze(HOLDER, 3000, 2, { from: FREEZE_MASTER });

            await vesting.claimAll({ from: HOLDER });

            assert.equal((await aliumToken.balanceOf(vesting.address)).toString(), 0);
        });
    });
});
