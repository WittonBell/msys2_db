#!env bash

set -e
set -o pipefail

REPO_URL="https://sourceforge.net/projects/msys2-snapshot/files/"

MINGW_URL="${REPO_URL}msys2/mingw/"
MSYS_URL="${REPO_URL}msys2/msys/"
DISTRIB_URL="${REPO_URL}msys2/distrib/"

MINGW_I686_URL="${MINGW_URL}i686/"
MINGW_X64_URL="${MINGW_URL}x86_64/"
MINGW_SOURCE_URL="${MINGW_URL}sources/"

MSYS_I686_URL="${MSYS_URL}i686/"
MSYS_X64_URL="${MSYS_URL}x86_64/"
MSYS_SOURCE_URL="${MSYS_URL}sources/"

DISTRIB_I686_URL="${MINGW_URL}i686/"
DISTRIB_X64_URL="${MINGW_URL}x86_64/"

XP_DISTRIB_URL="${DISTRIB_I686_URL}/msys2-i686-20150916.exe"

ALL_PKG_LIST="all_pkgs.txt"
LATEST_PKG_LIST="latest_pkgs.txt"
OUT_DIR="./i686"
DBNAME="mingw32"
CACHE_HTML="i686.html"

# 是否下载所有软件包，非0为下载所有，0为只下载最新版本
IS_DOWNLOAD_ALL=0
# 并行下载数量
PARALLEL_DOWNLOAD_NUM=16

PATH=/usr/bin

declare -A PkgName # 定义字典：Key为没有版本号的包名，Value为包括版本号的包名

check_tools() {
	if type wget > /dev/null ; then # 检查是否有wget工具
		# -q 静默
		# -c 支持断点续传（需要服务器支持，sourceforge.net不支持断点续传）
		# -t 重试次数 -T 超时时间 -w 重试等待时间
		# --show-progress 显示进度条
		# --progress=bar 进度条样式为bar,默认为dot
		# --no-check-certificate不检查安全证书，msys2-i686-20150916.exe太老，证书失效
		# -O 写入指定文件
		fetch='wget -qc -t 5 -T 30 -w 2 --show-progress --progress=bar  --no-check-certificate -O'
	elif type wget > /dev/null ; then  # 检查是否有curl工具
		# -k不检查安全证书，msys2-i686-20150916.exe太老，证书失效
		# -o 写入指定文件
		fetch='curl -ko'
	else
		echo "没有下载工具，需要下载wget或者curl"
		exit 1
	fi
	if ! type vercmp > /dev/null ; then
		echo 没有版本比较工具：vercmp
		exit 1
	fi
}

download_html() {
	if [ ! -s "$CACHE_HTML" ]; then # 检测$CACHE_HTML文件是否为空，-s为非空检测
		echo "下载: $CACHE_HTML"
		${fetch} "${CACHE_HTML}.part" "$MINGW_I686_URL"
		mv "${CACHE_HTML}.part" "${CACHE_HTML}"
	else
		echo "下载: $CACHE_HTML（已存在跳过）"
	fi
}

build_pkg_list() {
	if [ ! -s "$ALL_PKG_LIST" ]; then # 检测$ALL_PKG_LIST文件是否为空，-s为非空检测
		echo 生成 $ALL_PKG_LIST
		grep -oE '/i686/[^"]+pkg\.tar\.[a-z0-9]+/download' "$CACHE_HTML" | sed -n 's#.*/\([^/]*\)/download#\1#p' | sort -u > $ALL_PKG_LIST
	else
		echo "生成 $ALL_PKG_LIST (已存在跳过)"
	fi
}

compare_ver() {
	new=$1
	old=$2
	# 先判断是否为纯数字，是则直接按数值比较，否则按字符串比较
	if [[ $new =~ ^[0-9]+$ ]] && [[ $old =~ ^[0-9]+$ ]]; then
		if (($new > $old)); then
			echo 1
			return 0
		elif (($new < $old)); then
			echo -1
			return 0
		fi
	else
		if [[ $new > $old ]]; then
			echo 2
			return 0
		elif [[ $new < $old ]]; then
			echo -2
			return 0
		fi
	fi
	echo 0
}

record_pkg() {
	# mingw-w64-i686-3proxy-0.8.12-1-any.pkg.tar.xz
	local full_name=$1
	# 去掉-any.pkg.tar.xz，结果：mingw-w64-i686-3proxy-0.8.12-1
	local name1=${full_name%-*}
	# 去掉编译次数，结果：mingw-w64-i686-3proxy-0.8.12
	local name2=${name1%-*}
	# 去掉版本号，获取包名，结果：mingw-w64-i686-3proxy
	local name=${name2%-*}
	if [[ ${PkgName[$name]} == "" ]]; then # 如果没有记录，则记录包的全名及版本号
		PkgName[$name]=$full_name
	else
		# 之前有记录过，获取之前记录的版本号
		old=${PkgName[$name]}
		# 调用vercmp进行版本比较，版本号大则返回1，小则返回-1，相等返回0
		result=$(vercmp ${full_name} ${old})
		if (($result > 0)); then
			PkgName[$name]=$full_name
		fi
	fi
}

build_latest_pkg() {
	if ((IS_DOWNLOAD_ALL)); then
		LATEST_PKG_LIST=$ALL_PKG_LIST
	else
		if [ ! -s "${LATEST_PKG_LIST}" ]; then
			echo "生成最新版本软件包到 $LATEST_PKG_LIST"
			local total=$(wc -l < $ALL_PKG_LIST)
			local n=1
			while read -r name; do
				echo [$n/$total] $name
				let n+=1
				record_pkg $name
			done < "$ALL_PKG_LIST"

			local PKG_COUNT=${#PkgName[@]} # 获取PkgName字典的大小
			if [[ "$PKG_COUNT" == 0 ]]; then
				echo "错误：未检测到 pkg.tar.* 文件"
				exit 1
			fi
			# 保存所有最新版本到文件
			# 使用sed将空格替换成换行符，再排序，排序时不区分大小写
			echo ${PkgName[@]} | sed 's/\ /\n/g' | sort -f > $LATEST_PKG_LIST
		fi
	fi
}

download() {
	filename=$1
	local n=$2
	# 判断文件是否为空
	if [ -s "$filename" ]; then
		echo "[$n/$PKG_COUNT]已存在：$filename（跳过）"
		return 0
	fi
	URL="$MINGW_I686_URL$filename/download"
	echo "[$n/$PKG_COUNT]下载：$filename"
	# 下载到一个临时文件
	${fetch} "${filename}.part" "$URL"
	# 下载完成后改名
	mv "${filename}.part" "$filename"
}

parall_download() {
	# 导出函数，使子进程可以调用
	export -f download
	# 导出变量，使子进程可以使用
	export MINGW_I686_URL PKG_COUNT fetch
	# 将$LATEST_PKG_LIST文件内容读取到数组中
	readarray -t packages < $LATEST_PKG_LIST
	# 获取数组大小
	PKG_COUNT=${#packages[@]}
	echo "$LATEST_PKG 解析到 $PKG_COUNT 个软件包"
	if [[ "$PKG_COUNT" == 0 ]]; then
		echo "错误：未检测到 pkg.tar.* 文件"
		exit 1
	fi

	echo "开始下载软件包"
	cd $OUT_DIR
	# 生成序号并并行执行
	for i in "${!packages[@]}"; do
		# 计算序号（从1开始）
		idx=$((i + 1))
		echo "$idx ${packages[i]}" # 返回参数，第一个参数是序号,第二个参数是包名
	done | xargs -P "$PARALLEL_DOWNLOAD_NUM" -I {} bash -c ' # -I {} 会把所有参数作为一个整体传给bash
	args=($1)				# 把参数数组化
	idx=${args[0]}			# 取第一个参数：序号
	pkg=${args[1]}			# 取第二个参数：包名
	download "$pkg" "$idx"
' _ {}
}

build_db() {
	echo "生成数据库"
	rm -f "$DBNAME".db "$DBNAME".files "$DBNAME".db.tar.gz "$DBNAME".files.tar.gz
	repo-add "$DBNAME.db.tar.gz" *.pkg.tar.*
}

check_tools
download_html
build_pkg_list
build_latest_pkg
mkdir -p "$OUT_DIR"
parall_download
build_db
