# loader/

这个目录放 Sahara loader：`qsahara_device_programmer.xml` 和它列出的镜像。它们是联想/高通的文件，公开仓库**不随附**，从你自己的 CN 固件工具包里拷进来（上游说 loader 只认机型不认区域）。

作者用的那份 XML 写的芯片是 `kaanapali`，列了 8 个镜像：

- `multi_image_qti.mbn`
- `multi_image.mbn`
- `xbl_sc.elf`
- `signed_firmware_soc_view.elf`
- `sequencer_ram.elf`
- `tme_config.elf`
- `prog_firehose_ddr.elf`
- `xbl_config_devprg.elf`

用到这个目录的：`../tools/edl.sh`、`../tools/sahara_min.py`、仓库根目录的 `flash_coloros.py` 和 `linux/restore-coloros-boot.sh`。

---

This directory holds the Sahara loader: `qsahara_device_programmer.xml` and the images it lists. They are Lenovo/Qualcomm files and are **not included** in the public repository; copy them from your own CN firmware package (upstream reports that the loader is tied to the model, not the region). The author's XML names the chipset `kaanapali` and lists the eight images above. Used by `../tools/edl.sh`, `../tools/sahara_min.py`, the root `flash_coloros.py` and `linux/restore-coloros-boot.sh`.
