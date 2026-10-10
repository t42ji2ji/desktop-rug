<div align="center">

<img src="site/assets/icon.png" width="112" alt="Desktop Rug 圖示">

# Desktop Rug

鋪在 Mac 桌面上的一張厚地毯。亂七八糟的檔案，掃到底下就好。

[**下載 Mac 版**](https://github.com/t42ji2ji/desktop-rug/releases/latest/download/DesktopRug.dmg) · [官網](https://rug.dorara.app) · [English](README.md)

<a href="https://rug.dorara.app"><img src="site/assets/poster.jpg" width="640" alt="桌面上的地毯，上面有貓在走"></a>

</div>

## 有什麼

- **真的是一塊布。** 抓住任何一邊，地毯會被掀起、折起來，放手後帶著重量落下。角可以翻過來蓋住，再拉回去攤平。
- **蓋住桌面，不擋工作。** 地毯鋪在桌面那一層，在所有視窗底下。底下的檔案平常看不到，掀起一角才會露出來。
- **檔案堆會頂出凸起。** 地毯底下的圖示會把它頂起來，疊得越多，凸起越高。
- **貓。** 最多四隻貓住在地毯上：到處走、翻肚子撒嬌、抓癢、坐下來抬頭看螢幕。可以把牠拎起來放到別處。
- **任何花色。** 內建八款地毯，也可以把任何一張圖片變成地毯。

## 安裝

1. 下載 [DesktopRug.dmg](https://github.com/t42ji2ji/desktop-rug/releases/latest/download/DesktopRug.dmg)。
2. 打開後把 **Desktop Rug** 拖進「應用程式」。
3. 打開 Desktop Rug。它住在選單列（格紋圖示），Dock 上不會出現。

需要 macOS 14 以上、Apple 晶片的 Mac。

## 怎麼玩

| 動作 | 結果 |
|---|---|
| 拖地毯中間 | 整張滑過去 |
| 拖邊緣或角落 | 掀起、折起那一塊 |
| 對地毯按右鍵 | 打開編輯列：拖角落縮放、拖動位置、換花色、選要出現的貓 |
| 按住 ⌥（Option） | 同樣的編輯列，放開就收起 |
| 編輯列的 **+** | 用 Mac 上的圖片當地毯 |
| 拖一隻貓 | 把牠拎起來放到別處 |
| 編輯列的垃圾桶 | 把地毯折好收起來 |

其他功能都在選單列的圖示裡：重新鋪開地毯、移回螢幕中間、調整地毯的重量和軟硬、結束。

地毯可以在多個螢幕之間拖來拖去。

## 小提醒

- **「Desktop Rug 想要控制 Finder」**：第一次打開時 macOS 會問。這只用來讀取桌面圖示的位置，讓地毯在圖示上隆起。不允許也沒關係，地毯就保持平的。
- 要有凸起，Finder 得顯示桌面圖示。關掉的話地毯會保持平的。
- 被地毯完全蓋住的圖示點不到，把地毯移開或掀起一角就可以。
- 用 **+** 加入的圖片存在 `~/Library/Application Support/DesktopRug/patterns`。

## 移除

從選單列圖示選「結束」，再把「應用程式」裡的 Desktop Rug 丟進垃圾桶。要連加入的圖片一起清掉，刪除 `~/Library/Application Support/DesktopRug`。

## 致謝

靈感來自 [Terkel 的桌面地毯](https://x.com/terkelg/status/2107540718461886464)（[desktop.cleaning](https://desktop.cleaning)）。這是獨立重做的版本，跟原作沒有關係。

地毯花色和貓是用 ChatGPT 生圖畫的。

## 自己編譯

```sh
./build.sh && open build/DesktopRug.app
```

## 授權

[GPL-3.0](LICENSE)
