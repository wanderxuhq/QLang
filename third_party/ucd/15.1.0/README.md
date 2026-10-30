# Unicode Character Database 15.1.0(权威原始数据)

这三个文件是 **Unicode Consortium 发布的原文**,未经任何加工。它们是 Unicode 行为的
**一手来源**;`stdlib/unicode_data.ql` 是由它们生成的派生表,所以参照实现应当读这里,
而不是读那张派生表(否则就是"用 QLang 的表验证 QLang 的表")。

| 文件 | 用途 | SHA-256 |
|---|---|---|
| `UnicodeData.txt` | 每个码点的简单大写/小写映射(第 12/13 字段) | `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86` |
| `SpecialCasing.txt` | 多字符与上下文相关映射(`ß→SS`、希腊语尾 sigma) | `55a477efd933a52cd27e6a9bf70265bb2d8814af31aab07767abc8eb421f27ef` |
| `PropList.txt` | `White_Space` 等属性(`trim` 的依据) | `05672956317b6296bc2ec3d6cef1f6452b57ff4f2efc6dc55b0a19277d5fcfd1` |

来源:

```
https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt
https://www.unicode.org/Public/15.1.0/ucd/SpecialCasing.txt
https://www.unicode.org/Public/15.1.0/ucd/PropList.txt
```

获取日期 2026-10-30。校验:`sha256sum third_party/ucd/15.1.0/*.txt`。

更新版本时:换目录名(如 `16.0.0/`)、重算上表、并同步 `stdlib/generate_unicode_tables.py`
的输入版本 —— 两处版本不一致会让派生表与参照实现打架。

## 派生数据:`case-common.txt`

`case-common.txt` 是从上面的原文**派生**的参照输入(2450 行),生成命令(POSIX `awk`,不用 Python):

```sh
# 1) 取 U+0020..U+2FFF 里有简单大小写映射的行(码点;大写;小写)
awk -F';' 'NF>=14 && $1>="0020" && $1<="2FFF" && ($13!=""||$14!="") {print $1";"$13";"$14}' \
  UnicodeData.txt > case-common.txt

# 2) 去掉 SpecialCasing.txt 里出现过的码点(它们有"完整映射",例如 U+0130 → i + 组合点,
#    与 UnicodeData 的简单映射不同;这些冷门情形先不做)
awk -F';' '$1!~/^#/ && $1!="" {print $1}' SpecialCasing.txt | sort -u > /tmp/special.txt
awk -F';' 'NR==FNR{skip[$1]=1; next} !($1 in skip)' /tmp/special.txt case-common.txt > /tmp/cc.txt
mv /tmp/cc.txt case-common.txt
```

为什么不在运行时现读 `UnicodeData.txt`:见 `docs/unboxed-values-probes.md` §118.1(太慢)。
