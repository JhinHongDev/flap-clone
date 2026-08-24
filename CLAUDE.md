# 项目全局规范

详见 [AGENTS.md](./AGENTS.md)。所有智能体在进行代码生成和重构时必须严格遵循。

## 关键要点速览
1. **参考**: `https://flap.sh`，仅 BSC 网络，仅税收代币 (`FlapTaxTokenV3`)，暂不做靓号。
2. **严禁修改老合约**: `CoordinatorFactory.sol`, `presaleAA.sol`, `Token.sol`, `OpenZeppelinDependencies.sol`, `Interfaces.sol` 保持原样不改动。
3. **代码质量**: 严禁继承老版混乱低质的风格。强制使用 Custom Errors、CEI 安全模式、标准 NatSpec 注释、模块解耦与 100% Foundry 单元测试。
