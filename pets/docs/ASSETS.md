# 素材来源

- 宝可梦物种、中文名称、属性、身高、体重和进化链：[PokeAPI API data](https://github.com/PokeAPI/api-data/tree/02a8d9dd1b1a4e102b8b32d786d17017e8c9769a)，抓取 `/pokemon`、`/pokemon-species`、`/evolution-chain`。
- 动画：[PokeAPI sprites](https://github.com/PokeAPI/sprites/tree/a3a1432e688ea028f12c51371d5253037cb9f17b)，Generation V / Black & White / animated。PNG使用同仓库默认前视图。
- 抓取只选19个物种，JSON、PNG、GIF缓存后可离线运行。固定提交与生成清单在 [catalogue.json](../assets/catalogue.json)，脚本在 [fetch_pokemon.py](../scripts/fetch_pokemon.py)。网页使用GIF，设备使用脚本生成的4帧120×120 Flash图像。
- Pokémon名称及图像的权利归原权利人；此处记录素材来源，不把接口或工具的开源代码许可证视为图像的额外授权。
- 中文字体：[Noto Sans CJK SC Regular](https://github.com/notofonts/noto-cjk/blob/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf)，SIL Open Font License 1.1，许可保存在 [OFL.txt](../assets/fonts/OFL.txt)。使用 `lv_font_conv` 1.5.3 生成16/20px子集，ASCII之外，16px正文覆盖7445个可打印GB2312／界面字形，20px标题覆盖195个固定界面字形，源字体SHA256见 [fonts.json](../evidence/fonts.json)。

重新生成素材需要Pillow；生成字体需要Node和 `lv_font_conv`。这些工具仅用于构建，日常账本／网页／USB桥只依赖Python标准库，蓝牙桥额外使用Bleak3.0.1。原始个人Token统计与编译器缓存不属于素材包，均保存在忽略提交的 `.local/`。

放大版按GIF全部帧的透明边界求公共裁剪范围，再用最近邻放大到最大112px、居中放入120×120帧。使用公共范围保持动画锚点一致；网页主图显示范围调整到约200px。
