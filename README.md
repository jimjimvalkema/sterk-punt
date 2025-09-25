# AccountBasedPrivacy


```shell
VERSION=2.0.3 aztec start --sandbox --rollup-version 1714840162
```

compile
```shell
cd contracts/aztec/AccountBasedPrivacy;
aztec-nargo compile;
aztec-postprocess-contract 
aztec codegen -o src/artifacts target;
cd ../../..
```

test + compile
```shell
cd contracts/aztec/AccountBasedPrivacy;
aztec-nargo compile;
aztec-postprocess-contract
aztec codegen -o src/artifacts target;
cd ../../..
yarn test
```


## reproduce bugs:  
### no events: 
when you do `yarn test`. The test at `test/test.test.ts` logs the events at line 59, but the arrays are empty.  
  
### internal macro broken: 
uncomment line 176 at `contracts/aztec/AccountBasedPrivacy/src/main.nr` (and compile again) and run the test `yarn test` and you will get error: ` Assertion failed: Function increase_balance can only be called internally 'context.msg_sender() == context.this_address()'`   
  
### .wait({timeout}) not respected (timeout is alway 60s): 
idk how to reproduce. Sometimes it takes longer to mine the tx and it happens. It doesn't happen on timeout being < 60s
