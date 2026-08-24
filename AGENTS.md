# 项目开发规范与智能体全局准则 (AGENTS.md)

本文件是本项目（`flap-clone`）的全局开发规范。所有 AI 智能体（无论开启多少次新会话）均必须严格遵守以下准则。

---

## 1. 核心业务定位与模型架构

* **代币模板**：使用 `FlapTaxTokenV3` 作为唯一代币模板（固定 10 亿总量、买卖非对称税率、Anti-Farmer 防夹、动态清算阈值）。
* **唯一目标网络**：**仅支持 BSC（Binance Smart Chain）**，不编写任何多链兼容的冗余代码。
* **发币与预售解耦（预售可选，不扩展新发币方法）**：
  * **发币入口唯一**：统一使用 `FlapTokenFactory.createTaxToken()` 创建代币，10 亿枚全额发放给创建者，所有权移交创建者。
  * **预售是独立的后续可选步骤**：想开启预售的用户调用 `FlapPresaleFactory.createPresale()`，为其已持有的代币创建预售合约：
    * 将 **10 亿枚代币全额托管至预售合约**：**80%（8 亿枚）** 用于结束后自动加池，**20%（2 亿枚）** 用于散户 BNB 认购；
    * 代币所有权移交预售合约（供其结束时自动迁移状态机并加池开盘）；
    * 不开预售的用户则自行持有代币，直接去 PancakeSwap 加池开盘。
* **预售与加池模式（Presale & Liquidity）**：
  * 认购阶段：用户支付 BNB 参与认购；达到硬顶或手动结束（`finalizePresale`）时自动加池并永久销毁 LP。
  * **领取机制（主方案）**：分批线性释放（Vesting，TGE 比例 + 线性时长）；备选方案：开盘即领/可配延时。
  * **完全剔除老版内盘交易**：彻底移除 `trade()` / `tradeUnlock()` / `insidePrice` 等虚拟内盘逻辑。
* **交易税收分配机制（4通道）**：营销 (`marketBps`)、销毁 (`deflationBps`)、分红 (`dividendBps`)、自动加池 (`lpBps`)。
  * **非普通用户设置**：全局默认配置内置在 `TaxProcessor` 中，仅管理员可调。
* **功能简化**：**暂不实现** CREATE2 8888 靓号部署逻辑。
* **推进方式**：步进式推进，逐个模块开发、评审与单测。

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
