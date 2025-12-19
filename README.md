# msys2_db 
---

随着Windows系统版本的更新，MSYS2不再对老系统更新维护，比如Windows XP已经无法在主线MSYS2上更新使用了。
幸运的是在 [sourceforge.net](https://sourceforge.net/projects/msys2-snapshot/files/) 上有一个老版本的快照，可以正常安装使用，而且里面有一些新的版本可以使用，只是由于是快照，里面有一些包与db中的记录并不匹配，给安装带来不便。

本项目就是将 [sourceforge.net](https://sourceforge.net/projects/msys2-snapshot/files/) 快照仓库上的包重新生成db文件，方便安装。

### XP下MSYS2安装：

1. 下载并安装[msys2-i686-20150916.exe](https://sourceforge.net/projects/msys2-snapshot/files/msys2/distrib/i686/msys2-i686-20150916.exe/download)

2. 下载[pacman-mirrors-snapshot-20240724-1-any.pkg.tar.xz](https://sourceforge.net/projects/msys2-snapshot/files/pacman-mirrors-snapshot-20240724-1-any.pkg.tar.xz/download), 使用`pacman -U pacman-mirrors-snapshot-20240724-1-any.pkg.tar.xz`替换`MSYS2`的安装源

3. 修改/etc/pacman.conf，禁用签名检查：

   ```bash
   SigLevel = Never
   #SigLevel    = Required DatabaseOptional
   ```

4. 在MinGW32 Shell下执行`xp/mkdb.sh`，将生成的`mingw32.db`文件复制到`/var/lib/pacman/sync`下，复制前可以做一个备份。

