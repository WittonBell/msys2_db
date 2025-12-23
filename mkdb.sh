#!env bash

set -e
set -o pipefail

# 是否显示详细信息
verborse=0
# 是否下载所有软件包，非0为下载所有，0为只下载最新版本
IS_DOWNLOAD_ALL=0
# 并行下载数量
PARALLEL_NUM=16

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

OS="xp"
ARCH=32
TYPE="mingw"
URL="$MINGW_I686_URL"
FORCE=0
NODB=0
USE_CURL=0
ONLY_SPEC_PKG=1

usage() {
	echo "用法：${0##*/} [选项]"
	echo "默认只下载并使用指定包来更新db"
	echo "选项:"
	echo " -b <架构>，mingw默认为当前架构，可以是：32， 64"
	echo " -c 使用 curl 下载"
	echo " -d 只更新列表并下载，不全部生成DB"
	echo " -f 强制重新下载Web页面，解析所有包，生成最新包列表"
	echo " -p <并行下载数> 指定并行下载的数量，默认数量：$PARALLEL_NUM"
	echo " -s <目标系统>，默认为xp，目标系统可以是：xp，win7"
	echo " -t <类型> 指定生成的数据库类型，默认为mingw，可以是：mingw，msys"
	echo " -v 显示详细信息"

	exit 0
}

# 根据当前系统来决定使用msys的32位版本还是64位版本
detected_arch() {
	local sys=$(uname -a)
	local sys1=${sys% *}
	case ${sys1##* } in
		i686)
			ARCH=32
			URL="$MINGW_I686_URL"
			;;
		x86_64)
			ARCH=64
			URL="$MINGW_X64_URL"
			;;
		*)
			echo 未知的系统架构
			exit 1
			;;
	esac
}

detected_arch

# 解析命令行参数
while getopts ab:cdfhp:t:v opt ; do
	case $opt in
		b)
			ARCH="$OPTARG"
			case $ARCH in
				"32"|"64");;
				*)
					echo "不支持的架构，只支持32，64"
					usage
					;;
			esac;;
		c) USE_CURL=1 ;;
		d) NODB=1 ;;
		f)
			FORCE=1
			ONLY_SPEC_PKG=0
			;;
		h) usage ;;
		p) PARALLEL_NUM="$OPTARG" ;;
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
				mingw)
					TYPE="mingw"
					;;
				msys)
					TYPE="msys"
					;;
				*)
					usage
					;;
			esac
			;;
		v) verborse=1 ;;
		*) usage ;;
	esac
done

OUT_DIR="${OS}/${TYPE}${ARCH}"
CACHE_HTML="${OS}/${TYPE}${ARCH}.html"
ALL_PKG_LIST="${OS}/${TYPE}${ARCH}_all_pkgs.txt"
LATEST_PKG_LIST="${OS}/${TYPE}${ARCH}_latest_pkgs.txt"
SPEC_PKGS="${OS}/${TYPE}${ARCH}_spec_pkgs.txt"

PATH=/usr/bin

if [[ $TYPE == "msys" ]]; then
	DBNAME="msys"
	if (($ARCH == 32)); then
		URL=$MSYS_I686_URL
	else
		URL=$MSYS_X64_URL
	fi
else
	DBNAME="${TYPE}${ARCH}"
fi

if ((verborse)); then
	echo "架构：$ARCH"
	echo "输出目录：$OUT_DIR"
	echo "下载URL：$URL"
	echo "存储文件：$CACHE_HTML"
	echo "所有包存放到：$ALL_PKG_LIST"
	echo "最新包存放到：$LATEST_PKG_LIST"
	echo "使用特定版本的包：$SPEC_PKGS"
	echo "数据文件名：$DBNAME"
fi

declare -A PkgName # 定义字典：Key为没有版本号的包名，Value为包括版本号的包名

# 检查脚本需要使用到的工具
check_tools() {
	if ((! USE_CURL)) && type wget > /dev/null ; then # 检查是否有wget工具
		# -q 静默
		# -c 支持断点续传（需要服务器支持，sourceforge.net不支持断点续传）
		# -t 重试次数 -T 超时时间 -w 重试等待时间
		# --show-progress 显示进度条
		# --progress=bar 进度条样式为bar,默认为dot
		# --no-check-certificate不检查安全证书，msys2-i686-20150916.exe太老，证书失效
		# -O 写入指定文件
		if ((verborse)); then
			fetch='wget -c -t 5 -T 30 -w 2 --show-progress --progress=bar  --no-check-certificate -O'
		else
			fetch='wget -qc -t 5 -T 30 -w 2 --show-progress --progress=bar  --no-check-certificate -O'
		fi
	elif type curl > /dev/null ; then  # 检查是否有curl工具
		# -L 允许重定向。如果服务器反馈已移动到其它位置，即返回码3XX，则重新按新的地址请求资源
		# -k 不检查安全证书，msys2-i686-20150916.exe太老，证书失效
		# -o 写入指定文件
		# -v 显示详细信息
		# -# 显示进度条
		if ((verborse)); then
			fetch='curl --retry 5 --retry-delay 2 -# -v -Lko'
		else
			fetch='curl --retry 5 --retry-delay 2 -# -Lko'
		fi
	else
		echo "没有下载工具，需要下载wget或者curl"
		exit 1
	fi
	if ((! $ONLY_SPEC_PKG)) && ! type vercmp > /dev/null ; then
		echo 没有版本比较工具：vercmp
		exit 1
	fi
}

# 下载html文件
download_html() {
	if (($ONLY_SPEC_PKG)); then
		return 0
	fi
	if (($FORCE)) || [ ! -s "$CACHE_HTML" ]; then # 检测$CACHE_HTML文件是否为空，-s为非空检测
		echo "下载: $CACHE_HTML"
		if ((verborse)); then
			echo ${fetch} "${CACHE_HTML}.part" "$URL"
		fi
		${fetch} "${CACHE_HTML}.part" "$URL"
		mv -f "${CACHE_HTML}.part" "${CACHE_HTML}"
	else
		echo "下载: $CACHE_HTML（已存在，跳过）"
	fi
}

# 从下载的html文件中分析出可以下载的包
build_pkg_list() {
	if (($ONLY_SPEC_PKG)); then
		return 0
	fi
	if (($FORCE)) || [ ! -s "$ALL_PKG_LIST" ] || [ "$CACHE_HTML" -nt "$ALL_PKG_LIST" ]; then # 检测$ALL_PKG_LIST文件是否为空，-s为非空检测
		echo 生成 $ALL_PKG_LIST
		local re='/i686/[^"]+pkg\.tar\.[a-z0-9]+/download'
		if (($ARCH == 64)); then
			re='/x86_64/[^"]+pkg\.tar\.[a-z0-9]+/download'
		fi
		if ((verborse)); then
			echo "grep -oE $re $CACHE_HTML | sed -n 's#.*/\([^/]*\)/download#\1#p' | sort -u > $ALL_PKG_LIST"
		fi
		grep -oE $re "$CACHE_HTML" | sed -n 's#.*/\([^/]*\)/download#\1#p' | sort -u > $ALL_PKG_LIST
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
		if ((verborse)); then
			echo "使用特定版本 $full_name"
		fi
		let n+=1
	done < "$SPEC_PKGS"
	echo "使用 $SPEC_PKGS 中 ${n} 个包"
}

# 根据包全名记录版本号：record_pkg <包全名>
record_pkg() {
	# mingw-w64-i686-3proxy-0.8.12-1-any.pkg.tar.xz
	local full_name=$1
	local name=$(parse_name $full_name)
	# 之前有记录过，获取之前记录的版本号
	local old=${PkgName[$name]}
	if [[ $old == "" ]]; then # 如果没有记录，则记录包的全名及版本号
		PkgName[$name]=$full_name
		res="增加"
	else
		# 调用vercmp进行版本比较，版本号大则返回1，小则返回-1，相等返回0
		result=$(vercmp ${full_name} ${old})
		if (($result > 0)); then
			PkgName[$name]=$full_name
			res="更新"
		else
			res="不变"
		fi
	fi
}

# 生成最新版本的包
build_latest_pkg() {
	if (($ONLY_SPEC_PKG)); then
		LATEST_PKG_LIST=$SPEC_PKGS
		return 0
	fi
	if ((IS_DOWNLOAD_ALL)); then
		LATEST_PKG_LIST=$ALL_PKG_LIST
	else
		local file="$ALL_PKG_LIST"
		if (($FORCE)) || [ ! -s "${LATEST_PKG_LIST}" ] || [ "$ALL_PKG_LIST" -nt "${LATEST_PKG_LIST}" ]; then
			echo "生成 $LATEST_PKG_LIST"
		elif [ "$SPEC_PKGS" -nt "${LATEST_PKG_LIST}" ]; then
			file="$LATEST_PKG_LIST"
			echo "$SPEC_PKGS 比$LATEST_PKG_LIST 新，更新到 $LATEST_PKG_LIST"
		else
			echo "生成 ${LATEST_PKG_LIST} (已存在，跳过)"
			return 0
		fi
		local total=$(wc -l < $file)
		local n=0
		res=""
		while read -r name; do
			record_pkg $name
			let n+=1
			echo [$n/$total] $name $res
		done < "$file"

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
	URL="$URL$filename/download"
	echo "[$n/$PKG_COUNT]下载：$filename"
	if ((verborse)); then
		echo ${fetch} "${filename}.part" "$URL"
	fi
	# 下载到一个临时文件
	${fetch} "${filename}.part" "$URL"
	# 下载完成后改名
	mv "${filename}.part" "$filename"
}

parall_download() {
	# 导出函数，使子进程可以调用
	export -f download
	# 导出变量，使子进程可以使用
	export URL PKG_COUNT fetch verborse
	# 将$LATEST_PKG_LIST文件内容读取到数组中
	readarray -t packages < $LATEST_PKG_LIST
	# 获取数组大小
	PKG_COUNT=${#packages[@]}
	echo "$LATEST_PKG_LIST 解析到 $PKG_COUNT 个软件包"
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
	if ((! $ONLY_SPEC_PKG)); then
		echo 删除 "$DBNAME".db "$DBNAME".files "$DBNAME".db.tar.gz "$DBNAME".files.tar.gz
		rm -f "$DBNAME".db "$DBNAME".files "$DBNAME".db.tar.gz "$DBNAME".files.tar.gz
	fi
	repo-add "$DBNAME.db.tar.gz" ${packages[@]}
}

check_tools
download_html
build_pkg_list
build_latest_pkg
mkdir -p "$OUT_DIR"
parall_download
if ((! NODB)); then
	build_db
fi
