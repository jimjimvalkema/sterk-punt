# AccountBasedPrivacy


```shell
VERSION=2.0.3 aztec start --sandbox
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
cd contracts/aztec/AccountBasedPrivacy; VERSION=2.0.3  aztec-nargo compile; VERSION=2.0.3  aztec codegen -o src/artifacts target; cd ../../..; 
yarn test
```