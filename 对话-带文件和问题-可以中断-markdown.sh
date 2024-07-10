#!/bin/bash

# 定义要处理的目录和文件路径
DIRS_AND_FILES=(
src/components/queryvector/QueryVectorForm.vue
src/components/queryvector/QueryVectorTable.vue
)
# 任务
ask="要求QueryVectorTable选择数据库使用一个databaseinfo, 并将其传递进入QueryVectorForm"
# 角色
System='程序员'



# AI配置
API_URL="http://192.168.3.14:3000/v1/chat/completions"
OPENAI_API_KEY="sk-SyzHBKZrGzNbFZ8a7eF7Bc6846A94189B34fEdC0F6F902A5"
MODEL="deepseek-coder"

# 捕捉 SIGINT (Ctrl+C) 信号
trap handle_sigint SIGINT

# 定义命名管道文件
PIPE_FILE="/tmp/ai_response_pipe"

# 创建命名管道
if [[ ! -p $PIPE_FILE ]]; then
    mkfifo $PIPE_FILE
fi

# 定义一个函数以处理文件并获取内容
get_file_content() {
    local file="$1"
    local extension="${file##*.}"
    {
        echo "## $file"
        echo ""
        echo "\`\`\`$extension"
        cat "$file"
        echo ""
        echo "\`\`\`"
        echo ""
    }
}

# 定义一个函数以遍历路径并获取文件内容
process_paths() {
    local FILE_CONTENT=""
    for path in "${DIRS_AND_FILES[@]}"; do
        if [ -d "$path" ]; then
            for file in "$path"/*; do
                [ -f "$file" ] && FILE_CONTENT+=$(get_file_content "$file")
            done
        elif [ -f "$path" ]; then
            FILE_CONTENT+=$(get_file_content "$path")
        else
            echo "路径无效或不存在：$path"
        fi
    done
    echo "$FILE_CONTENT"
}

# 发送请求并获取响应函数（流式处理）
send_request() {
    add_to_history "user" "$1"
    local request_body=$(jq -c . < "$HISTORY_FILE" | jq --arg model "$MODEL" '{model: $model, messages: .} + {"stream": true}')
    local ai_response=""
    local pid=""
    (
        curl -sS -H "Content-Type: application/json" \
             -H "Authorization: Bearer $OPENAI_API_KEY" \
             -d "$request_body" \
             "$API_URL" > $PIPE_FILE
    ) &

    pid=$!
    while IFS= read -r line; do
        clean_line=$(echo "$line" | sed 's/^data: //')
        [[ "$clean_line" == "[DONE]" ]] && add_to_history "assistant" "$ai_response" && break
        content=$(echo "$clean_line" | jq '.choices[0].delta.content // empty'| sed 's/^"//; s/"$//' | sed 's/\\"/"/g')
        [[ -n "$content" ]] && ai_response+="$content" && printf "%b" "$content"
    done < $PIPE_FILE | bat --paging=never -l md --style=plain
    echo
}

# 添加消息到历史记录文件
add_to_history() {
    jq --arg role "$1" --arg content "$2" '. + [{"role": $role, "content": $content}]' "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# 捕捉 Ctrl+C 信号处理函数
handle_sigint() {
    if [ -n "$pid" ]; then
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
        echo -e "\n请求中断。"
    else
        echo -e "\n结束对话。"
        rm -f $PIPE_FILE
        exit 0
    fi
}

# 创建历史记录目录
HISTORY_DIR="history"
mkdir -p "$HISTORY_DIR"

# 初始化历史记录文件
HISTORY_FILE="$HISTORY_DIR/history_$(date +%Y%m%d%H%M%S).json"
FILE_CONTENT=$(process_paths)
# 确保请求体是单行的
FILE_CONTENT=$(echo "$FILE_CONTENT" | jq -Rs '.')
# 创建初始历史记录文件内容
echo "[{\"role\": \"system\", \"content\": \"$System\"},{\"role\": \"user\", \"content\": $FILE_CONTENT}]" > "$HISTORY_FILE"

# 初始请求
echo "system: $System"
echo "你: "
printf "%b" "$FILE_CONTENT"
echo "你: $ask"
echo -n "AI: "
send_request "$ask"


# 连续对话循环
while true; do
    read -e -p "你: " user_input
    [[ "$user_input" == "退出" ]] && echo "结束对话。" && rm -f $PIPE_FILE && break
    echo -n "AI: "
    send_request "$user_input"
done
