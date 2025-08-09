# AccountBasedPrivacy


```shell
aztec start --sandbox
```

compile
```shell
cd contracts/aztec/AccountBasedPrivacy;
aztec-nargo compile;
aztec codegen -o src/artifacts target;
cd ../../..
```

test + compile
```shell
cd contracts/aztec/AccountBasedPrivacy; aztec-nargo compile; aztec codegen -o src/artifacts target; cd ../../..; yarn test
```