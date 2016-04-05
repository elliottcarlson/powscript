# parse args
date=$(date +%Y%m%d%H%M%S)
rand=$(cat /dev/urandom | tr -cd [:alnum:] | head -c 4)
ID=$date"_"$rand
includefuncs=""
requires=""
tmpfile="/tmp/.$(whoami).powscript.$date_$rand"
ps1="${PS1//\\u/$USER}"; p="${p//\\h/$HOSTNAME}"
evalstr=""
evalstr_cache=""
shopt -s extglob

input=$1
if [[ ! -n $startfunction ]]; then 
  startfunction=runfile
fi

empty "$1" && {
  echo 'Usage:
     powscript <file.powscript>
     powscript --compile <file.powscript>
     powscript --interactive
     powscript --evaluate <powscript string>
  ';
}

for arg in "$@"; do
  case "$arg" in
    --interactive)
      startfunction="console process"
      shift
      ;;
    --evaluate)
      startfunction=evaluate
      shift
      ;;
    --compile) 
      startfunction=compile
      shift
      ;;
  esac
done

transpile_sugar(){
  while IFS="" read -r line; do 
    stack_update "$line"
    [[ "$line" =~ ^(require )                         ]] && continue
    [[ "$line" =~ (\$[a-zA-Z_0-9]*\[)                 ]] && transpile_array_get "$line"                  && continue
    [[ "$line" =~ ^([ ]*for line from )               ]] && transpile_foreachline_from "$line"           && continue
    [[ "$line" =~ ^([ ]*for )                         ]] && transpile_for "$line"                        && continue
    [[ "$line" =~ ^([ ]*when done)                    ]] && transpile_when_done "$line"                  && continue
    [[ "$line" =~ (await .* then for line)            ]] && transpile_then "$line" "pl" "pipe_each_line" && continue
    [[ "$line" =~ (await .* then \|)                  ]] && transpile_then "$line" "p"  "pipe"           && continue
    [[ "$line" =~ (await .* then)                     ]] && transpile_then "$line"                       && continue
    [[ "$line" =~ ^([ ]*if )                          ]] && transpile_if  "$line"                        && continue
    [[ "$line" =~ ^([ ]*switch )                      ]] && transpile_switch "$line"                     && continue
    [[ "$line" =~ ^([ ]*case )                        ]] && transpile_case "$line"                       && continue
    [[ "$line" =~ ([a-zA-Z_0-9]\+=)                   ]] && transpile_array_push "$line"                 && continue
    [[ "$line" =~ ^([a-zA-Z_0-9]*\([a-zA-Z_0-9, ]*\)) ]] && transpile_function "$line"                   && continue
    echo "$line" | transpile_all
  done <  $1
  stack_update ""
}

cat_requires(){
  while IFS="" read -r line; do 
    [[ "$line" =~ ^(require ) ]] && {                                               # include require-calls
      local file="${line//*require /}"; file="${file//[\"\']/}"
      echo -e "#\n# $line (included by powscript\n#\n"
      cat "$file";
    };
  done <  $1
  echo "" 
}

transpile_functions(){
  # *FIXME* this is bruteforce: if functionname is mentioned in textfile, include it
  while IFS="" read -r line; do 
    regex="((^|[ ])${powfunctions// /[ ]|(^|[ ])})"                                                  # include powscript-functions
    echo "$line" | grep -qE "$regex" && {
      for func in $powfunctions; do
        if [[ "$line" =~ ([ ]?$func[ ]) ]]; then 
          includefuncs="$includefuncs $func"; 
        fi
      done;
    }
  done <  $1
  [[ ! ${#includefuncs} == 0 ]] && echo -e "#\n# generated by powscript (https://github.com/coderofsalvation/powscript)\n#\n"
  for func in $includefuncs; do 
    declare -f $func; echo ""; 
  done
}

compile(){
  local dir="$(dirname "$1")"; local file="$(basename "$1")"; cd "$dir" &>/dev/null
  { cat_requires "$file" ; echo -e "#\n# application code\n#\n"; cat "$file"; } > $tmpfile
  echo -e "$settings"
  #transpile_functions "$tmpfile"
  transpile_sugar "$tmpfile" | grep -v "^#" > $tmpfile.code
  transpile_functions $tmpfile.code
  cat $tmpfile.code
  for i in ${!footer[@]}; do echo "${footer[$i]}"; done 
  rm $tmpfile
}


process(){
  evalstr="$evalstr\n""$*"
  if  [[ ! "$*" =~ ^([A-Za-z_0-9]*=) ]]  && \
      [[ ! "$*" =~ \)$ ]]                && \
      [[ ! "$*" =~ ^([ ][ ]) ]]; then 
    evaluate "$evalstr"
  fi
}

evaluate(){
  echo -e "$*" > $tmpfile
  evalstr_cache="$evalstr_cache\n$*"
  [[ -n $DEBUG ]] && echo "$(transpile_sugar $tmpfile)"
  eval "$(transpile_sugar $tmpfile)"
  evalstr=""
}

edit(){
  local file=/tmp/$(whoami).pow
  echo -e "#!/usr/bin/env powscript$evalstr_cache" | grep -vE "^(edit|help)" > $file && chmod 755 $file
  $EDITOR $file
}

help(){
  echo '
  FUNCTION                  foo(a,b)
                              switch $a
                                case [0-9])
                                  echo 'number!'
                                case *)
                                  echo 'anything!'

  IF-STATEMENT              if not $j is "foo" and $x is "bar"
                              if $j is "foo" or $j is "xfoo"
                                if $j > $y and $j != $y or $j >= $y
                                  echo "foo"
  
  READ FILE BY LINE         for line from $selfpath/foo.txt
                              echo "->"$line

  REGEX                     if $f match ^([f]oo)
                              echo "foo found!"    

  PIPEMAP                   myfunc()
                              echo "line=$1"

                            echo -e "foo\nbar\n" | pipemap myfunc
                            # outputs: 'value=foo' and 'value=bar'

  MATH                      math '9 / 2'
                            math '9 / 2' 4
                            # outputs: '4' and '4.5000'
                            # NOTE: the second requires bc 
                            # to be installed for floatingpoint math

  ASYNC                     myfunc()
                              sleep 1s
                              echo "one"

                            await myfunc 123 then
                              echo "async done"

                            # see more: https://github.com/coderofsalvation/powscript/wiki/Reference

  CHECK ISSET / EMPTY       if isset $1
                              echo "no argument given"
                            if not empty $1
                              echo "string given"
  
  ASSOC ARRAY               foo={}
                            foo["bar"]="a value"

                            for k,v in foo
                                echo k=$k
                                  echo v=$v
                                    
                                  echo $foo["bar"]

  INDEXED ARRAY             bla=[]
                            bla[0]="foo"
                            bla+="push value"

                            for i in bla
                                echo bla=$i

                                echo $bla[0]


  SOURCE POWSCRIPT FILE     require foo.pow

  SOURCE BASH FILE          source foo.bash

  see more at: https://github.com/coderofsalvation/powscript/wiki/Reference
  
  ' | less
}

console(){
  [[ ! $1 == "1" ]] && echo "hit ctrl-c to exit powscript, type 'edit' launch editor, and 'help' for help"
  trap 'console 1' 0 1 2 3 13 15 # EXIT HUP INT QUIT PIPE TERM SIGTERM SIGHUP
  while IFS="" read -r -e -d $'\n' -p "> " line; do
    "$1" "$line"
    history -s "$line"
  done
}

runfile(){
  file=$1; shift;
  eval "$(compile "$file")"
}

${startfunction} "$@" #"${0//.*\./}"
