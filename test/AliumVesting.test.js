// eslint-disable-next-line no-unused-vars
const {
  BN,
  constants,
  expectEvent,
  expectRevert,
  time,
  ether
} = require('@openzeppelin/test-helpers');
const { accounts, defaultSender } = require('@openzeppelin/test-environment');
const { default: BigNumber } = require('bignumber.js');
const { assert, expect } = require('chai');

const AliumVesting = artifacts.require('AliumVesting');
const ALM = artifacts.require('MockALM');
const AliumCash = artifacts.require('MockAliumCashbox');

const moment = require('moment');
const should = require('chai').should();

let cashbox, vesting, aliumToken;

describe('AliumVesting contract', () => {
  const initialOwner = accounts[0];
  const tokenPool = accounts[1];
  const userBob = accounts[2];
  const userAlice = accounts[3];
  const userClark = accounts[4];
  let r = { logs:'' };

  beforeEach(async function () {
    this.aliumToken = await ALM.new();
    this.cashbox = await AliumCash.new();
    await this.cashbox.initialize(this.aliumToken.address, initialOwner);
    this.vesting = await AliumVesting.new(this.aliumToken.address, this.cashbox.address, userClark);
    await this.vesting.addLockPlan(0, [60*60*24*7, 60*60*24*14, 60*60*24*21], [33, 33, 34]);
    await this.vesting.addLockPlan(1, [60*60*24*5, 60*60*24*10, 60*60*24*15, 60*60*24*20], [25, 25, 25, 25]);
    await this.vesting.addLockPlan(2, [60*60*24*3, 60*60*24*6, 60*60*24*9, 60*60*24*12, 60*60*24*15], [20, 20, 20, 20, 20]);

    await this.aliumToken.transfer(this.cashbox.address, ether('250000000'));
    await this.cashbox.setWalletLimit(this.vesting.address, ether('50000000'));
  });

  describe('As a generic user we', async function () {
    it('Cannot freeze tokens by ourself', async function () {
      await this.aliumToken.transfer(userBob, ether('5000'));
      let b = await this.aliumToken.balanceOf(userBob);
      assert.equal(b.toString(10), ether('5000').toString(10));
      expectRevert(this.vesting.freeze(userBob, ether('5000'), 1, {from: userBob}), 'Method not allowed');
    });

    it('Can get simple frozen token balance', async function () {
      const PLAN_ID = 1
      let tx = await this.vesting.freeze(userBob, ether('9000'), PLAN_ID); // freeze 9000
      expectEvent.inLogs(tx.logs,'TokensLocked');

      console.log("Gas used for freeze: %d", tx.receipt.gasUsed);

      let balance = await this.vesting.getBalanceOf(userBob, PLAN_ID);

      assert.equal(balance.totalBalance.toString(), ether('9000').toString());
      assert.equal(balance.frozenBalance.toString(), ether('9000').toString());
      assert.equal(balance.withdrawnBalance.toString(), '0');
    });

    it.skip('Can get frozen balances with several consecutive locks', async function () {
      await this.aliumToken.transfer(this.vesting.address, 8000);
      await this.vesting.freeze(userBob, 8000, 2); // freeze 8000 quarterly

      let releaseTime = (await time.latest()).add(time.duration.days(92));
      await time.increaseTo(releaseTime);
      let b = await this.vesting.balanceOf(userBob);
      assert.equal(b, 8000);
      b = await this.vesting.unlockedBalanceOf(userBob);
      assert.equal(b, 2000);
      await time.increaseTo(releaseTime.add(time.duration.days(92)));
      b = await this.vesting.balanceOf(userBob);
      assert.equal(b, 8000);
      b = await this.vesting.unlockedBalanceOf(userBob);
      assert.equal(b, 4000);
    });

    it('Can get frozen virtual balances', async function () {

    });

    it('Can claim partially unlocked tokens', async function () {

    });

    it('Can mint virtual tokens', async function () {
    });

    it('Can view own locks', async function () {
    });

    it('Can view own stats', async function () {
    });

    it('Can get next unlock date', async function () {

    });

    it('Cannot view other users locks', async function () {

    });

  });

  describe('As an admin user we', async function () {
    beforeEach(async function() {
      await this.aliumToken.transfer(this.vesting.address, 4000);
      await this.vesting.freeze(userBob, 4000, 1); // freeze 9000 for 2 years quarterly
    });

    it('Can freeze tokens', async function () {

    });

    it('Can get user locks length', async function () {

    });

    it('Can view own locks', async function () {

    });

    it('Can view all locks', async function () {

    });
  });
});
