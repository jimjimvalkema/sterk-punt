import { AztecAddress, Contract,createPXEClient,waitForPXE, Fr, GrumpkinScalar, type PXE, AccountWalletWithSecretKey  } from '@aztec/aztec.js';
import { getDeployedTestAccountsWallets } from '@aztec/accounts/testing';
import { AccountBasedPrivacyContract } from '../contracts/aztec/AccountBasedPrivacy/src/artifacts/AccountBasedPrivacy';
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

describe("accountBasedPrivacy", () => {
    let wallets:AccountWalletWithSecretKey[]
    let PXE:PXE
    beforeAll(async () => {
        console.log(crypto.getRandomValues(new Uint8Array(new Array(32).fill(0))))
        const PXE_URL = process.env.PXE_URL || 'http://localhost:8080';
        PXE = createPXEClient(PXE_URL) as PXE;
        //@ts-ignore
        wallets  = await getDeployedTestAccountsWallets(PXE) as AccountWalletWithSecretKey[]
    })
    it("should spend", async () => {
        const walletDeployer = wallets[0] as AccountWalletWithSecretKey
        const walletAlice = wallets[1] as AccountWalletWithSecretKey
        const walletBob = wallets[2] as AccountWalletWithSecretKey
        const accountBasedPrivacy = await AccountBasedPrivacyContract.deploy(walletDeployer).send().deployed()
        const res = accountBasedPrivacy.withWallet(walletAlice).methods.transfer(walletBob.getAddress(),1n).send().wait()
        console.log({res})
    })
});