#!/bin/bash

HOST="secure6.www.apple.com.cn"
PORT="443"
COUNT=5 # 测试次数
TIMEOUT=2 # 单次连接超时时间 (秒)
SUM_LATENCY=0
SUCCESS_COUNT=0

echo "TCP Pinging ${HOST}:${PORT} for ${COUNT} times..."

for i in $(seq 1 $COUNT); do
    START_TIME=$(date +%s.%N)
    # 使用 -w 设置超时，/dev/null 重定向输出以免干扰计时
    if nc -zv -w $TIMEOUT $HOST $PORT &> /dev/null; then
        END_TIME=$(date +%s.%N)
        LATENCY=$(echo "$END_TIME - $START_TIME" | bc -l)
        # 将秒转换为毫秒以便与 itdog.cn (毫秒) 对比，乘以 1000
        LATENCY_MS=$(echo "$LATENCY * 1000" | bc -l)
        printf "  Ping %d: successful, time=%.2f ms\n" "$i" "$LATENCY_MS"
        SUM_LATENCY=$(echo "$SUM_LATENCY + $LATENCY_MS" | bc -l)
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  Ping ${i}: failed or timed out."
    fi
    sleep 0.5 # 每次测试之间稍微停顿一下
done

if [ $SUCCESS_COUNT -gt 0 ]; then
    AVG_LATENCY=$(echo "$SUM_LATENCY / $SUCCESS_COUNT" | bc -l)
    echo "--- ${HOST}:${PORT} TCP ping statistics ---"
    echo "${SUCCESS_COUNT} connections succeeded out of ${COUNT} attempts"
    printf "Average latency: %.2f ms\n" "$AVG_LATENCY"
else
    echo "Failed to connect to ${HOST}:${PORT} in all attempts."
fi
