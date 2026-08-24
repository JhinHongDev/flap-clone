# 项目开发规范与智能体全局准则 (AGENTS.md)

本文件是本项目（`flap-clone`）的全局开发规范。所有 AI 智能体（无论开启多少次新会话）均必须严格遵守以下准则。

---

## 1. 核心业务定位与模型架构

* **代币模板**：使用 `FlapTaxTokenV3` 作为唯一代币模板（固定 10 亿总量、买卖非对称税率、Anti-Farmer 防夹、动态清算阈值）。
* **唯一目标网络**：**仅支持 BSC（Binance Smart Chain）**，不编写任何多链兼容的冗余代码。

> 其余业务细节（如发币/预售托管比例、代币分配、领取机制、税收通道等）随产品演进而变动，由实际代码为准，本文件不做说明。

---

## 2. 文件与代码隔离准则（绝对红线）

* **严禁修改老版代码**：
  * `src/legacy/CoordinatorFactory.sol`
  * `src/legacy/presaleAA.sol`
  * `src/legacy/Token.sol`
  * `src/legacy/OpenZeppelinDependencies.sol`
  * `src/legacy/Interfaces.sol`
  这些老文件仅供历史参考，**任何情况下都不得改动**。
* **新文件独立创建**：所有重构后的新合约均创建于全新的独立文件中（如 `src/FlapPresaleFactory.sol`, `src/FlapTaxProcessor.sol`, `src/FlapPresale.sol` 等）。

---

## 3. 代码质量与工程规范（严禁继承老版代码风格）

AI 智能体作为资深 Solidity 专家，必须以工业级生产标准编写代码，**绝对不要继承老版合约的低质编码习惯**：

1. **错误处理**：全面采用现代 Solidity **Custom Errors**（如 `error ZeroAddress()`），杜绝大段字符串 `require(..., "STRING_REASON")` 以节省 Gas。
2. **安全防护**：
   * 严格遵循 **CEI (Checks-Effects-Interactions)** 模式防范重入。
   * 严格执行边界检查（如买卖税率上限、防溢出、零地址、流动性滑点防夹）。
3. **架构解耦**：
   * 保持高内聚低耦合，严禁跨合约的冗余状态同步与混乱的 try-catch 链。
   * Token、Factory、TaxProcessor、Dividend、Presale 各自职责单一清晰。
4. **文档与规范**：所有公共接口、结构体、事件与错误均配备规范的 **NatSpec 注释**（`@notice`, `@dev`, `@param`, `@return`）。
5. **测试驱动**：每个新合约必须配备对应的 Foundry 单元测试（`test/*.t.sol`），确保 `forge test` 100% 通过。
