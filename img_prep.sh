set -ex
export OUT_FILE=pip/img.h

doImg(){
  echo "doing $1"
  printf 'static const ' >> $OUT_FILE
  xxd -i $1 >> $OUT_FILE
}

export -f doImg


cat /dev/null > $OUT_FILE
find img -type f -name '*.png' | xargs -L 1 bash -c 'doImg "$@"' _

cat $OUT_FILE
