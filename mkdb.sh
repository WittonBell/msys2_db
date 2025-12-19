#!env bash

set -e
set -o pipefail

# 是否下载所有软件包，非0为下载所有，0为只下载最新版本
IS_DOWNLOAD_ALL=0
# 并行下载数量
PARALLEL_NUM=16

OS="xp"
DBNAME="mingw32"

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

XP_DISTRIB_URL="${DISTRIB_I686_URL}/msys2-i686-20150916.exe/download"

usage() {
	echo "用法：${0##*/} [选项]"
	echo "选项:"
	echo " -a 下载全部包，默认只下载最新版本"
	echo " -p <并行下载数> 指定并行下载的数量，默认数量：$PARALLEL_NUM"
	echo " -s <目标系统>，默认为xp，目标系统可以是：xp，win7"
	echo " -t <类型> 指定生成的数据库类型，默认为mingw32，可以是：mingw32，mingw64，msys"

	exit 0
}

# 解析命令行参数
while getopts ahp:t: opt ; do
	case $opt in
		a)
			echo "将要下载全部包"
			IS_DOWNLOAD_ALL=1
			;;
		h)
			usage
			;;
		p)
			PARALLEL_NUM="$OPTARG"
			echo "并行下载数：$PARALLEL_NUM"
			;;
		s)
			case "$OPTARG" in
				xp)
					OS="xp"
					;;
				win7)
					OS="win7"
					;;
				*)
					usage
					;;
			esac
			;;
		t)
			case "$OPTARG" in
				mingw32)
					DBNAME="mingw32"
					;;
				mingw64)
					DBNAME="mingw64"
					;;
				msys)
					DBNAME="msys"
					;;
				*)
					usage
					;;
			esac
			;;
		*)
			usage
			;;
	esac
done

OUT_DIR="${OS}/${DBNAME}"
CACHE_HTML="${OS}/${DBNAME}.html"
ALL_PKG_LIST="${OS}/${DBNAME}_all_pkgs.txt"
LATEST_PKG_LIST="${OS}/${DBNAME}_latest_pkgs.txt"
SPEC_PKGS="${OS}/${DBNAME}_spec_pkgs.txt"

PATH=/usr/bin

declare -A PkgName # 定义字典：Key为没有版本号的包名，Value为包括版本号的包名

# 检查脚本需要使用到的工具
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

# 下载html文件
download_html() {
	if [ ! -s "$CACHE_HTML" ]; then # 检测$CACHE_HTML文件是否为空，-s为非空检测
		echo "下载: $CACHE_HTML"
		${fetch} "${CACHE_HTML}.part" "$MINGW_I686_URL"
		mv "${CACHE_HTML}.part" "${CACHE_HTML}"
	else
		echo "下载: $CACHE_HTML（已存在，跳过）"
	fi
}

# 从下载的html文件中分析出可以下载的包
build_pkg_list() {
	if [ ! -s "$ALL_PKG_LIST" ]; then # 检测$ALL_PKG_LIST文件是否为空，-s为非空检测
		echo 生成 $ALL_PKG_LIST
		grep -oE '/i686/[^"]+pkg\.tar\.[a-z0-9]+/download' "$CACHE_HTML" | sed -n 's#.*/\([^/]*\)/download#\1#p' | sort -u > $ALL_PKG_LIST
	else
		echo "生成 $ALL_PKG_LIST (已存在，跳过)"
	fi
}

# 解析包的基本名：parse_name <包全名>
# mingw-w64-i686-3proxy-0.8.12-1-any.pkg.tar.xz 解析后为 mingw-w64-i686-3proxy
parse_name() {
	# mingw-w64-i686-3proxy-0.8.12-1-any.pkg.tar.xz
	local full_name=$1
	# 去掉-any.pkg.tar.xz，结果：mingw-w64-i686-3proxy-0.8.12-1
	local name1=${full_name%-*}
	# 去掉编译次数，结果：mingw-w64-i686-3proxy-0.8.12
	local name2=${name1%-*}
	# 去掉版本号，获取包名，结果：mingw-w64-i686-3proxy
	echo ${name2%-*}
}

# 使用 $SPEC_PKGS 文件中指定版本的包: apply_spec_pkg <包数组>
apply_spec_pkg() {
	if [ ! -s "$SPEC_PKGS" ]; then # 如果文件不存在或者为空则直接返回
		return 0
	fi
	local -n ar=$1 # 创建$1数组的引用
	local n=0
	while read -r full_name; do
		name=$(parse_name $full_name)
		# 将名字为$name的包替换成指定包
		ar[$name]=$full_name
		let n+=1
	done < "$SPEC_PKGS"
	echo "使用 $SPEC_PKGS 中 ${n} 个包"
}

# 根据包全名记录版本号：record_pkg <包全名>
record_pkg() {
	# mingw-w64-i686-3proxy-0.8.12-1-any.pkg.tar.xz
	local full_name=$1
	name=$(parse_name $full_name)
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

# 生成最新版本的包
build_latest_pkg() {
	if ((IS_DOWNLOAD_ALL)); then
		LATEST_PKG_LIST=$ALL_PKG_LIST
	else
		if [ ! -s "${LATEST_PKG_LIST}" ]; then
			echo "生成 $LATEST_PKG_LIST"
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
			# 应用特定的包版本
			apply_spec_pkg PkgName
			# 保存所有最新版本到文件
			# 使用sed将空格替换成换行符，再排序，排序时不区分大小写
			echo ${PkgName[@]} | sed 's/\ /\n/g' | sort -f > $LATEST_PKG_LIST
		else
			echo "生成 ${LATEST_PKG_LIST} (已存在，跳过)"
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
	done | xargs -P "$PARALLEL_NUM" -I {} bash -c ' # -I {} 会把所有参数作为一个整体传给bash
	args=($1)				# 把参数数组化
	idx=${args[0]}			# 取第一个参数：序号
	pkg=${args[1]}			# 取第二个参数：包名
	download "$pkg" "$idx"
' _ {}
}

build_db() {
	echo "生成数据库"
	rm -f "$DBNAME".db "$DBNAME".files "$DBNAME".db.tar.gz "$DBNAME".files.tar.gz
	repo-add "$DBNAME.db.tar.gz" ${packages[@]}
}

check_tools
download_html
build_pkg_list
build_latest_pkg
mkdir -p "$OUT_DIR"
parall_download
build_db
