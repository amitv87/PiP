set -ex
OUT_FILE=pip/img.h

cat /dev/null > $OUT_FILE

doImg(){
  printf 'static const ' >> $OUT_FILE
  xxd -i img/$1.png >> $OUT_FILE
}

doImg pop
doImg play
doImg pause

cat $OUT_FILE
