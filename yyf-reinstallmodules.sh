#!/bin/bash
set -e
echo "== 0) 先清干净占用者，否则 modprobe -r 必失败 =="
systemctl stop nvidia-persistenced nvidia-dcgm 2>/dev/null || true
docker ps -aq | xargs -r docker rm -f 2>/dev/null || true
fuser -k /dev/nvidia* 2>/dev/null || true
sleep 2
echo "== 1) 编译(含 src/nvidia → nv-kernel.o) =="
make clean
make modules -j$(nproc)
echo "== 2) 卸载旧模块 —— 必须确认成功，否则中止 =="
modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
if lsmod | grep -q "^nvidia "; then
    echo "!! 旧模块未卸载(仍被占用)。若继续，你会以为装了新模块、实际跑的是旧的。中止。"
    lsmod | grep nvidia; fuser -v /dev/nvidia* 2>&1 | head
    exit 1
fi
echo "== 3) 安装(先装后 depmod) =="
make modules_install
depmod -a
echo "== 3.5) 重建 initramfs —— 否则下次重启会加载旧模块 =="
# 2026-07-31 踩过: initramfs 里压着 RPM 版 nvidia.ko(25 MB, 2025-03-13)，
# 开机时抢在 /lib/modules 里刚编的那个(39 MB)之前加载并常驻。
# 本次 modprobe 起来的是新模块、当轮测试正常，一重启就悄悄换回旧的 ——
# 结果是拿旧驱动跑了半小时"验证补丁"的测试。
# 第 5 步的 srcversion 校验只在此刻有效，管不到重启之后。
if command -v dracut >/dev/null 2>&1; then
    dracut -f --kver "$(uname -r)" 2>/dev/null && echo "   ✓ initramfs 已重建"
    # 用 srcversion 比对，不要用文件尺寸: dracut 默认 strip 模块，
    # initramfs 里的 .ko 必然比磁盘上小(实测 39815960 -> 25161512)，
    # 按尺寸判会稳定误报。srcversion 在 .modinfo 段，strip -g 不会动它。
    kver=$(uname -r)
    kmod_rel="usr/lib/modules/${kver}/kernel/drivers/video/nvidia.ko"
    tmpd=$(mktemp -d)
    if (cd "$tmpd" && lsinitrd --unpack "/boot/initramfs-${kver}.img" >/dev/null 2>&1) \
       && [ -f "${tmpd}/${kmod_rel}" ]; then
        insv=$(modinfo -F srcversion "${tmpd}/${kmod_rel}" 2>/dev/null)
        dksv=$(modinfo -F srcversion nvidia 2>/dev/null)
        if [ -n "$insv" ] && [ "$insv" = "$dksv" ]; then
            echo "   ✓ initramfs 内 nvidia.ko 与磁盘一致 ($insv)"
        else
            echo "   ✗ initramfs($insv) 与磁盘($dksv) 不一致，下次重启仍会跑旧模块"
            rm -rf "$tmpd"; exit 1
        fi
    else
        echo "   (initramfs 内无 nvidia.ko 或无法解包，跳过比对)"
    fi
    rm -rf "$tmpd"
else
    echo "   ! 未找到 dracut，请自行确认 initramfs 里没有陈旧的 nvidia.ko"
fi
echo "== 4) 加载 =="
modprobe nvidia && modprobe nvidia_drm && modprobe nvidia_modeset && modprobe nvidia_uvm
echo "== 5) ★硬校验: 内存里跑的必须就是刚编的那个 =="
loaded=$(cat /sys/module/nvidia/srcversion 2>/dev/null)
ondisk=$(modinfo -F srcversion nvidia 2>/dev/null)
echo "   loaded : $loaded"
echo "   on-disk: $ondisk"
if [ -n "$loaded" ] && [ "$loaded" = "$ondisk" ]; then
    echo "   ✓ 一致，新模块确已生效"
else
    echo "   ✗ 不一致！跑的不是新模块"; exit 1
fi
