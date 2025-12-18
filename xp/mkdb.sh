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

declare -A PkgName
declare -A PkgVer

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
	# 去掉-any.pkg.tar.xz，剩下：mingw-w64-i686-3proxy-0.8.12-1
	local name1=${full_name%-*}
	# 获取编译次数
	local buildCount=${name1##*-}
	# 去掉编译次数
	local name2=${name1%-*}
	# 去掉版本号，获取包名
	local name=${name2%-*}
	# 获取版本号
	local ver=${name2##*-}
	declare -a arVer # 声明一个索引数组
	while [ $ver ]
	do
		v=${ver%%.*} # 从后向前去掉内容，直到第一个点号，即取第一个点前面的版本号
		ver=${ver#*.} # 从前向后去掉内容，直到第一个点号，即取第一个点后面的版本号
		if [[ $v == "0" ]]; then
			arVer+=($v) # 如果只有一个0则保留
		else
			arVer+=("${v#"${v%%[!0]*}"}") # 添加去除前导零的数组元素
		fi
		if [[ $ver != *"."* ]]; then # 如果没有点号，只有唯一的一个版本号了
			if [[ $ver == "0" ]]; then
				arVer+=($ver)  # 如果只有一个0则保留
			else
				arVer+=("${ver#"${ver%%[!0]*}"}") # 添加去除前导零的数组元素
			fi
			break
		fi
	done
	arVer+=($buildCount)
	#echo 数组:${arVer[@]}
	if [[ ${PkgName[$name]} == "" ]]; then
		#echo 添加 $name
		PkgName[$name]=$full_name
		PkgVer[$name]=${arVer[@]}
	else
		oldVer=(${PkgVer[$name]}) # 需要转换成数组
		#计算两个数组的最大长度
		maxlen=$((${#arVer[@]} > ${#oldVer[@]} ? ${#arVer[@]} : ${#oldVer[@]}))
		for ((i=0; i < $maxlen; i++))
		{
			result=$(compare_ver ${arVer[$i]} ${oldVer[$i]})
			if (($result > 0)); then
				#echo 更新 $full_name
				PkgVer[$name]=${arVer[@]}
				PkgName[$name]=$full_name
				return 0
			elif (($result < 0)); then
				return 0
			fi
		}
	fi
}

build_latest_pkg() {
	if ((IS_DOWNLOAD_ALL)); then
		LATEST_PKG_LIST=$ALL_PKG_LIST
	else
		if [ ! -s "${LATEST_PKG_LIST}" ]; then
			echo "生成最新版本软件包到 $LATEST_PKG_LIST"
			local total=$(wc -l < $ALL_PKG_LIST)
			local n=0
			while read -r name; do
				echo [$n/$total] $name
				let n+=1
				record_pkg $name
			done < "$ALL_PKG_LIST"

			local PKG_COUNT=${#PkgName[@]}
			if [[ "$PKG_COUNT" == 0 ]]; then
				return
			fi
			for name in "${!PkgName[@]}"
			{
				full_name=${PkgName[${name}]}
				echo $full_name >> temp.txt
			}
			sort temp.txt > $LATEST_PKG_LIST
			rm -rf temp.txt
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
	${fetch} "${filename}.part" "$URL"
	mv "${filename}.part" "$filename"
}

parall_download() {
	# 导出函数，使子进程可以调用
	export -f download
	# 导出变量，使子进程可以使用
	export MINGW_I686_URL PKG_COUNT fetch
	readarray -t packages < $LATEST_PKG_LIST
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
		# 跳过空行
		[[ -z "${packages[i]}" ]] && continue
		# 计算序号（从1开始）
		idx=$((i + 1))
		echo "$idx ${packages[i]}"
	done | xargs -n 2 -P "$PARALLEL_DOWNLOAD_NUM" -I {} bash -c '
	args=($1)
	idx=${args[0]}
	pkg=${args[1]}
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
mkdir -p "$OUT_DIR"
build_latest_pkg
parall_download
build_db
