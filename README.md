# Brent Xu 的运维知识库

个人运维知识库博客：沉淀运维工作中的笔记与经验。

- 框架：Hugo Extended 0.169.0 + PaperMod 主题
- 部署：GitHub Actions 自动构建并发布到 GitHub Pages
- 地址：https://xxbbzy.github.io/

## 本地构建

```bash
# Hugo 二进制位于 ~/workspace/blog/tools/hugo（扩展版，0.169.0）
~/workspace/blog/tools/hugo --minify
# 生成结果在 public/；本地预览：
~/workspace/blog/tools/hugo server -D
```

## 构建自检

`scripts/check-site.sh` 检查六个必要产物是否存在且非空、已发布文章是否出现在
`llms.txt` 中、文本产物是否包含内网地址或敏感参数标记，以及站点地图是否包含欢迎文章。
每项检查输出 PASS 或 FAIL，任一失败都会以非零退出码结束；CI 在构建后、上传产物前执行此检查。

在站点根目录运行：

```bash
~/workspace/blog/tools/hugo --minify
bash scripts/check-site.sh ./public
```

省略参数时默认检查 `./public`，也可传入其他构建产物目录。

## 新增文章

```bash
~/workspace/blog/tools/hugo new content/posts/<slug>.md
```

按 `archetypes/default.md` 填写 frontmatter（title、date、tags、categories、summary），
写完后把 `draft` 改为 `false` 再发布。

## AI 可读

- `llms.txt`：文章索引（标题、URL、摘要），Hugo 自定义输出生成
- `llms-full.txt`：全部文章全文拼接，Hugo 自定义输出生成
- `sitemap.xml`、`index.xml`（RSS）、`index.json`（站内搜索索引）由 Hugo 生成

## 主题

PaperMod 不提交进仓库，由 GitHub Actions 在构建时克隆并固定到提交
`118119693d8b5ac211b939775678310973bcb232`。本地构建时主题位于 `themes/PaperMod`
（已被 .gitignore 排除），升级主题时同步更新 workflow 里的固定提交号。
