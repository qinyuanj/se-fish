-- 已取证棘轮的基线（#326）：由 `lua tools/cli.lua acceptance --update-baseline` 写入，只许单向调整。
-- evidenced（从 spec、probes 与 evidence/*/session.md 反推出的已取证条款数）只增：
-- 调低就是悄悄丢掉已验收的能力；反方向的 --update-baseline 直接拒绝并退 2。
return {
  evidenced = 156,
  updated = "2026-11-24",
}
