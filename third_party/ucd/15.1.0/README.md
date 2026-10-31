# Unicode Character Database 15.1.0(权威原始数据)

这四个文件是 **Unicode Consortium 发布的原文**,未经任何加工。它们是 Unicode 行为的
**一手来源**;`stdlib/unicode_data.ql` 是由它们生成的派生表,所以参照实现应当读这里,
而不是读那张派生表(否则就是"用 QLang 的表验证 QLang 的表")。

| 文件 | 用途 | SHA-256 |
|---|---|---|
| `UnicodeData.txt` | 每个码点的简单大写/小写映射(第 12/13 字段) | `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86` |
| `SpecialCasing.txt` | 多字符与上下文相关映射(`ß→SS`、希腊语尾 sigma) | `55a477efd933a52cd27e6a9bf70265bb2d8814af31aab07767abc8eb421f27ef` |
| `DerivedCoreProperties.txt` | `Cased` / `Case_Ignorable`(Final_Sigma 的依据) | `f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b` |
| `PropList.txt` | `White_Space` 等属性(`trim` 的依据) | `05672956317b6296bc2ec3d6cef1f6452b57ff4f2efc6dc55b0a19277d5fcfd1` |

来源:

```
https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt
https://www.unicode.org/Public/15.1.0/ucd/SpecialCasing.txt
https://www.unicode.org/Public/15.1.0/ucd/DerivedCoreProperties.txt
https://www.unicode.org/Public/15.1.0/ucd/PropList.txt
```

获取日期 2026-10-30。校验:`sha256sum third_party/ucd/15.1.0/*.txt`。

更新版本时:换目录名(如 `16.0.0/`)、重算上表、并同步 `aot/generate_unicode_tables.ql`
的输入版本 —— 两处版本不一致会让派生表与参照实现打架。

下面所有派生文件都由 **POSIX `awk`** 从上面的原文生成(不用 Python),在**本目录**执行。
`aot/unicode_oracle.ql` 只读这些派生文件,不读 `stdlib/unicode_data.ql`。

## 派生数据:`case-full.txt`(全平面简单映射)

`UnicodeData.txt` 里**所有平面**中至少有一个简单大写/小写映射的码点,格式 `码点;大写;小写`
(空字段表示该方向无映射)。共 2879 行。

```sh
awk -F';' '
function h2d(s,   i,c,v,digits){ digits="0123456789ABCDEF"; v=0;
  for(i=1;i<=length(s);i++){ c=toupper(substr(s,i,1)); v=v*16+(index(digits,c)-1) } return v }
NF>=14 && ($13!=""||$14!="") { printf "%06X;%s;%s\n", h2d($1), $13, $14 }' \
  UnicodeData.txt > case-full.txt
```

## 派生数据:`case-special.txt`(无条件完整映射)

`SpecialCasing.txt` 中**无条件**行(第 5 字段去掉注释后为空)的完整大写/小写映射,
格式 `码点;大写;小写`,按码点排序。共 103 行;条件行(希腊语 `Final_Sigma`、
土耳其语/立陶宛语区域规则)不在这里,`Final_Sigma` 由参照实现按 UCD 规则单独处理,
区域规则与 Python `str.upper/lower` 一样不实现。

```sh
awk -F';' '
function h2d(s,   i,c,v,digits){ digits="0123456789ABCDEF"; v=0;
  for(i=1;i<=length(s);i++){ c=toupper(substr(s,i,1)); v=v*16+(index(digits,c)-1) } return v }
function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
$1!~/^#/ && $1!="" { cond=$5; sub(/#.*/,"",cond);
  if(trim(cond)=="") printf "%06X;%s;%s\n", h2d(trim($1)), trim($4), trim($2) }' \
  SpecialCasing.txt | LC_ALL=C sort > case-special.txt
```

## 派生数据:`cased.txt` / `case-ignorable.txt`

`DerivedCoreProperties.txt` 的 `Cased` 与 `Case_Ignorable` 区间(每行 `XXXX` 或
`XXXX..YYYY`)。它们是 `Final_Sigma` 判定的独立依据。

```sh
awk -F';' 'function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
$1!~/^#/ && $1!="" { p=$2; sub(/#.*/,"",p); p=trim(p); if(p=="Cased") print trim($1) }' \
  DerivedCoreProperties.txt > cased.txt

awk -F';' 'function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
$1!~/^#/ && $1!="" { p=$2; sub(/#.*/,"",p); p=trim(p); if(p=="Case_Ignorable") print trim($1) }' \
  DerivedCoreProperties.txt > case-ignorable.txt
```

## 派生数据:`case-common.txt`(旧参照输入,保留)

`case-common.txt` 是早期 U+0020..U+2FFF 的子集(2450 行),现在仍留在目录里供历史对照,
但 `aot/unicode_oracle.ql` 已改用全平面的 `case-full.txt` + `case-special.txt`。生成命令:

```sh
# 1) 取 U+0020..U+2FFF 里有简单大小写映射的行(码点;大写;小写)
awk -F';' 'NF>=14 && $1>="0020" && $1<="2FFF" && ($13!=""||$14!="") {print $1";"$13";"$14}' \
  UnicodeData.txt > case-common.txt

# 2) 去掉 SpecialCasing.txt 里出现过的码点(它们有"完整映射",例如 U+0130 → i + 组合点,
#    与 UnicodeData 的简单映射不同)
awk -F';' '$1!~/^#/ && $1!="" {print $1}' SpecialCasing.txt | sort -u > /tmp/special.txt
awk -F';' 'NR==FNR{skip[$1]=1; next} !($1 in skip)' /tmp/special.txt case-common.txt > /tmp/cc.txt
mv /tmp/cc.txt case-common.txt
```

为什么不在运行时现读 `UnicodeData.txt`:见 `docs/unboxed-values-probes.md` §118.1(太慢)。

## 派生数据:`whitespace.txt`

`whitespace.txt`(25 个码点)同样从 `PropList.txt` 派生:

```sh
awk 'function h2d(s,   i,c,v,digits){ digits="0123456789ABCDEF"; v=0;
  for(i=1;i<=length(s);i++){ c=toupper(substr(s,i,1)); v=v*16+(index(digits,c)-1) } return v }
BEGIN{ FS=";" }
/; White_Space #/ { gsub(/[ \t]/,"",$1); k=index($1,"..");
  if (k>0) { lo=h2d(substr($1,1,k-1)); hi=h2d(substr($1,k+2)) } else { lo=h2d($1); hi=lo }
  for(p=lo;p<=hi;p++){ printf "%04X\n", p } }' PropList.txt > whitespace.txt
```

注意 `awk` 的 `split(s, a, "..")` 里第三个参数是**正则**,`..` 会匹配任意两个字符 —— 所以上面用
`index()` 找范围分隔符,不要用 `split`。
