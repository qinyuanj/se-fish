-- 双棘轮的基线（#243）：由 `lua tools/cli.lua acceptance --update-baseline` 写入，只许单向调整。
-- evidenced（已取证条款数 = evidenced + accepted）只增：调低就是悄悄丢掉已验收的能力。
-- legacyTests（fast 与 full 车道实际发现的测试文件数，剔除 spec 等条款断言车道）只减：清理不许停在半路。
-- 调高 evidenced 或调低 legacyTests 之后才允许重写本文件；反方向的 --update-baseline 直接拒绝并退 2。
return {
  evidenced = 156,
  legacyTests = 114,
  updated = "2026-11-24",
}
