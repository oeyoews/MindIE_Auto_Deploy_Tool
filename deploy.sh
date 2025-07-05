#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置文件
CONFIG_FILE="deploy_config.json"
CONTAINER_CACHE=".container_cache"  # 容器缓存文件

# 检查是否在Docker环境中
in_docker_env() {
    [ -f "/.dockerenv" ]
}

# 检查依赖
check_dependencies() {
    local deps=("docker")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}错误: 未找到命令 '$dep'${NC}"
            echo "请先安装必要的依赖"
            exit 1
        fi
    done
}

    
# 使用Python读取配置和获取IP
read_config() {
    python3 -c "
import json

def format_nodes(nodes):
    if isinstance(nodes, list):
        return '\\n'.join(nodes)
    return nodes

def format_volumes(volumes):
    if isinstance(volumes, dict):
        return '\\n'.join(f'{k}={v}' for k, v in volumes.items())
    return volumes

def get_nested_value(data, path):
    keys = path.split('.')
    value = data
    for key in keys:
        if isinstance(value, dict):
            value = value.get(key)
        else:
            return None
    return value

with open('$CONFIG_FILE') as f:
    config = json.load(f)
    path = '$1'
    value = get_nested_value(config, path)
    
    if path == 'nodes':
        print(format_nodes(value))
    elif path == 'docker.volumes':
        print(format_volumes(value))
    else:
        print('' if value is None else value)
"
}

# 验证配置文件
validate_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到配置文件 $CONFIG_FILE${NC}"
        exit 1
    fi
    
    # 获取world_size判断部署模式
    local world_size=$(read_config "world_size")
    if [ -z "$world_size" ]; then
        echo -e "${RED}错误: 配置文件缺少必要字段 'world_size'${NC}"
        exit 1
    fi
    
    if [ "$world_size" -lt 9 ]; then
        # 单机部署配置校验
        echo -e "${BLUE}校验单机部署配置...${NC}"
        local required_fields=("container_ip" "model_name" "model_path" "docker.image")
        for field in "${required_fields[@]}"; do
            if [ -z "$(read_config "$field")" ]; then
                echo -e "${RED}错误: 配置文件缺少必要字段 '$field'${NC}"
                exit 1
            fi
        done
        
        # 检查world_size范围
        if [ "$world_size" -lt 1 ] || [ "$world_size" -gt 8 ]; then
            echo -e "${RED}错误: world_size必须在1-8之间${NC}"
            exit 1
        fi
        
        # 检查device_ids配置
        local device_ids=$(read_config "device_ids")
        if [ ! -z "$device_ids" ]; then
            # 如果指定了device_ids，检查数量是否匹配world_size
            local device_count=$(python3 -c "
import json
device_ids = json.loads('$device_ids')
print(len(device_ids))
")
            if [ "$device_count" != "$world_size" ]; then
                echo -e "${RED}错误: device_ids数量($device_count)与world_size($world_size)不匹配${NC}"
                exit 1
            fi
            
            # 检查device_ids是否都在合法范围内
            local has_invalid_ids=$(python3 -c "
import json
device_ids = json.loads('$device_ids')
invalid = any(d < 0 or d > 7 for d in device_ids)
print('true' if invalid else '')
")
            if [ ! -z "$has_invalid_ids" ]; then
                echo -e "${RED}错误: device_ids中包含无效的设备ID (必须在0-7之间)${NC}"
                exit 1
            fi
        fi
    else
        # 多机部署配置校验
        echo -e "${BLUE}校验多机部署配置...${NC}"
        local required_fields=("master_ip" "nodes" "model_name" "model_path" "docker.image")
        for field in "${required_fields[@]}"; do
            if [ -z "$(read_config "$field")" ]; then
                echo -e "${RED}错误: 配置文件缺少必要字段 '$field'${NC}"
                exit 1
            fi
        done

        # 检查SSH端口配置
        local ssh_port=$(read_config "ssh.port")
        if [ "$ssh_port" = "null" ]; then
            echo -e "${BLUE}注意: 未指定SSH端口，将使用默认端口22${NC}"
        fi

        # 增加SSH认证配置检查
        local use_key=$(read_config "ssh.use_key")
        local key_path=$(read_config "ssh.key_path")
        local password=$(read_config "ssh.password")
        
        if [ "$use_key" = "true" ]; then
            if [ -z "$key_path" ] || [ "$key_path" = "null" ]; then
                echo -e "${RED}错误: 使用SSH密钥认证但未指定密钥路径${NC}"
                exit 1
            fi
            # 展开路径中的~
            key_path=$(eval echo "$key_path")
            if [ ! -f "$key_path" ]; then
                echo -e "${RED}错误: SSH密钥文件不存在: $key_path${NC}"
                echo -e "${BLUE}请检查：${NC}"
                echo -e "1. 密钥文件路径是否正确"
                echo -e "2. 密钥文件权限是否正确 (建议: chmod 600 $key_path)"
                exit 1
            fi
            # 检查密钥文件权限
            local key_perms=$(stat -c %a "$key_path")
            if [ "$key_perms" != "600" ]; then
                echo -e "${RED}警告: SSH密钥文件权限不正确 ($key_perms)${NC}"
                echo -e "${BLUE}建议执行: chmod 600 $key_path${NC}"
            fi
        else
            if [ -z "$password" ] || [ "$password" = "null" ]; then
                echo -e "${RED}错误: 使用密码认证但未提供密码${NC}"
                exit 1
            fi
        fi
    fi
}

# 检查必要文件
check_files() {
    local required_files=(
        "lib/auto_check.sh"
        "lib/add_env_settings.sh"
        "lib/generate_ranktable.py"
        "lib/modify_mindie_config.py"
        "lib/push_mem.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            echo -e "${RED}错误: 缺少必要文件 $file${NC}"
            exit 1
        fi
        # 添加执行权限
        chmod +x "$file" 2>/dev/null
    done
}

# 添加容器管理相关函数
cleanup_previous_container() {
    if [ ! -f "$CONTAINER_CACHE" ]; then
        return 0
    fi
    
    local prev_container=$(cat "$CONTAINER_CACHE")
    if [ -n "$prev_container" ]; then
        echo -e "${BLUE}发现之前的容器: $prev_container${NC}"
        if docker ps -a --format '{{.Names}}' | grep -q "^${prev_container}$"; then
            echo -e "${BLUE}正在停止并删除之前的容器...${NC}"
            if ! docker stop "$prev_container"; then
                echo -e "${RED}停止容器失败${NC}"
                return 1
            fi
            
            # 等待容器完全停止
            while docker ps --format '{{.Names}}' | grep -q "^${prev_container}$"; do
                echo -e "${BLUE}等待容器停止...${NC}"
                sleep 1
            done
            
            if ! docker rm "$prev_container"; then
                echo -e "${RED}删除容器失败${NC}"
                return 1
            fi
            echo -e "${GREEN}之前的容器已清理${NC}"
        fi
    fi
    return 0
}

wait_for_container_ready() {
    local container_name="$1"
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
            # 检查容器是否真正就绪
            if docker exec "$container_name" true >/dev/null 2>&1; then
                echo -e "${GREEN}容器已就绪${NC}"
                return 0
            fi
        fi
        echo -e "${BLUE}等待容器就绪... ($attempt/$max_attempts)${NC}"
        sleep 1
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}等待容器就绪超时${NC}"
    return 1
}

# 在文件开头添加错误处理函数
cleanup_and_exit() {
    local exit_code=$1
    local error_msg=$2
    local container_name=$([ -f "$CONTAINER_CACHE" ] && cat "$CONTAINER_CACHE")
    
    echo -e "${RED}错误: $error_msg${NC}"
    
    # 清理容器
    if [ -n "$container_name" ]; then
        echo -e "${BLUE}清理容器: $container_name${NC}"
        docker rm -f "$container_name" >/dev/null 2>&1
    fi
    
    # 清理内存预热进程
    if ps aux | grep -v grep | grep push_mem.sh > /dev/null; then
        echo -e "${BLUE}清理内存预热进程...${NC}"
        pkill -f push_mem.sh
    fi
    
    # 清理服务进程
    if ps aux | grep -v grep | grep mindieservice_daemon > /dev/null; then
        echo -e "${BLUE}清理服务进程...${NC}"
        pkill -f mindie_llm_back
        sync; echo 3 > /proc/sys/vm/drop_caches
    fi
    
    exit $exit_code
}

# 启动Docker容器并执行部署
start_docker_and_deploy() {
    local image=$(read_config "docker.image")
    local model_path=$(read_config "model_path")
    local container_name="npu_deploy_$(date +%s)"
    
    # 清理之前的容器
    cleanup_previous_container || cleanup_and_exit 1 "清理之前的容器失败"
    
    echo -e "${BLUE}启动Docker容器...${NC}"
    
    # 从配置文件获取volumes配置
    local volumes_json=$(read_config "docker.volumes")
    local volumes_args=""
    
    # 将volumes配置转换为-v参数
    while IFS="=" read -r host_path container_path; do
        if [ ! -z "$host_path" ] && [ ! -z "$container_path" ]; then
            volumes_args="$volumes_args -v $host_path:$container_path"
        fi
    done <<< "$volumes_json"
    
    # 调用start_docker.sh脚本，传递volumes参数
    chmod a+x lib/start_docker.sh
    ./lib/start_docker.sh "$container_name" "$image" "$volumes_args"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: Docker容器启动失败${NC}"
        exit 1
    fi
    
    # 等待容器就绪
    wait_for_container_ready "$container_name" || {
        docker rm -f "$container_name" >/dev/null 2>&1
        cleanup_and_exit 1 "容器未能正常启动"
    }
    
    # 记录容器名称到缓存文件
    echo "$container_name" > "$CONTAINER_CACHE"
    
    echo -e "${GREEN}容器启动成功: $container_name${NC}"
    
    # 在容器中创建工作目录和mindie目录
    echo -e "${BLUE}创建容器工作目录...${NC}"
    docker exec "$container_name" mkdir -p /workspace
    docker exec "$container_name" mkdir -p /usr/local/Ascend/mindie/latest/mindie-service/
    
    # 复制必要文件到容器
    echo -e "${BLUE}复制配置文件到容器...${NC}"
    docker cp "$CONFIG_FILE" "$container_name:/workspace/"
    docker cp . "$container_name:/workspace/"
    docker cp /usr/bin/hostname "$container_name:/usr/bin/"
    
    # 复制rank表到指定目录
    if [ -f "rank_table_file.json" ]; then
        echo -e "${BLUE}复制rank表到容器...${NC}"
        docker cp rank_table_file.json "$container_name:/usr/local/Ascend/mindie/latest/mindie-service/"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}rank表复制成功${NC}"
        else
            echo -e "${RED}错误: rank表复制失败${NC}"
            cleanup_and_exit 1 "rank表复制失败"
        fi
    else
        echo -e "${RED}错误: 未找到rank表文件${NC}"
        cleanup_and_exit 1 "rank表文件不存在"
    fi
    
    # 在容器中执行部署流程
    echo -e "${BLUE}开始执行部署流程...${NC}"
    if ! docker exec -it "$container_name" bash -l -c "cd /workspace && chmod +x deploy.sh && ./deploy.sh --in-container"; then
        echo -e "${RED}错误: 容器内部署失败${NC}"
        echo -e "${BLUE}清理容器...${NC}"
        docker rm -f "$container_name" >/dev/null 2>&1
        exit 1
    fi

    # 退出容器重进以达成刷新环境变量的目的
    echo -e "${BLUE}开始启动服务...${NC}"
    if ! docker exec -it "$container_name" bash -l -c "cd /workspace && chmod +x deploy.sh && ./deploy.sh --start-service"; then
        echo -e "${RED}错误: 容器内启动服务失败${NC}"
        echo -e "${BLUE}清理容器...${NC}"
        docker rm -f "$container_name" >/dev/null 2>&1
        exit 1
    fi
}


# 容器内部署流程
deploy_in_container() {
    echo -e "${BLUE}=== 开始容器内部署 ===${NC}"
    
    # 5. 配置环境变量
    echo -e "\n${GREEN}[4/8] 配置环境变量...${NC}"
    
    # 获取IP和配置
    nodes=$(read_config "nodes")
    current_ip=$(hostname -I | awk -v nodes="$nodes" '
BEGIN {
    n = split(nodes, node_array, "\n")
}
{
    for(i=1; i<=NF; i++) {
        for(j=1; j<=n; j++) {
            if ($i == node_array[j]) {
                print $i
                exit
            }
        }
    }
}')

    if [ -z "$current_ip" ]; then
        echo -e "${RED}错误: 未能在nodes列表中找到匹配的本机IP地址${NC}"
        exit 1
    fi
    world_size=$(read_config "world_size") || cleanup_and_exit 1 "获取world_size失败"
    master_ip=$(read_config "master_ip") || cleanup_and_exit 1 "获取master_ip失败"
    
    chmod a+x lib/add_env_settings.sh
    ./lib/add_env_settings.sh "$master_ip" "$current_ip" "$world_size" || cleanup_and_exit 1 "环境变量配置失败"
    
    # 6. 修改Mindie服务配置
    echo -e "\n${GREEN}[5/8] 修改Mindie服务配置...${NC}"

    # 从配置文件获取参数
    model_name=$(read_config "model_name")
    model_path=$(read_config "model_path")

    # 构建命令行参数
    cmd="python3 lib/modify_mindie_config.py"
    cmd="$cmd --master-ip $master_ip"
    cmd="$cmd --model-name $model_name"
    cmd="$cmd --model-path $model_path"
    cmd="$cmd --world-size $world_size"

    # 执行配置修改
    eval "$cmd" || cleanup_and_exit 1 "Mindie服务配置修改失败"
    
    # 7. 内存预热
    echo -e "\n${GREEN}[6/8] 执行内存预热...${NC}"
    # 从配置文件获取模型路径
    model_path=$(read_config "model_path") || cleanup_and_exit 1 "获取model_path失败"
    
    if [ -d "$model_path" ]; then
        # 复制预热脚本到模型目录
        cp lib/push_mem.sh "$model_path/" || cleanup_and_exit 1 "复制预热脚本失败"
        
        # 切换到模型目录并执行预热
        current_dir=$(pwd)
        cd "$model_path" || cleanup_and_exit 1 "切换到模型目录失败"
        echo -e "${BLUE}开始在 $model_path 目录下执行内存预热...${NC}"
        nohup bash push_mem.sh > output_mem.log 2>&1 &
        cd "$current_dir"
        
        # 等待预热脚本启动
        sleep 2
        ps -ef | grep push_mem.sh  || cleanup_and_exit 1 "内存预热进程启动失败"
    else
        echo -e "${RED}警告: 模型目录不存在: $model_path${NC}"
        echo -e "${RED}跳过内存预热${NC}"
    fi
}

start_service() {
    # 8. 启动服务
    echo -e "\n${GREEN}[7/8] 启动服务...${NC}"
    model_path=$(read_config "model_path") || {
        echo -e "${RED}错误: 获取model_path失败${NC}"
        exit 1
    }

    # 获取IP和配置
    nodes=$(read_config "nodes")
    current_ip=$(hostname -I | awk -v nodes="$nodes" '
BEGIN {
    n = split(nodes, node_array, "\n")
}
{
    for(i=1; i<=NF; i++) {
        for(j=1; j<=n; j++) {
            if ($i == node_array[j]) {
                print $i
                exit
            }
        }
    }
}')

    if [ -z "$current_ip" ]; then
        echo -e "${RED}错误: 未能在nodes列表中找到匹配的本机IP地址${NC}"
        exit 1
    fi
    master_ip=$(read_config "master_ip") || {
        echo -e "${RED}错误: 获取master_ip失败${NC}"
        exit 1
    }
    
    world_size=$(read_config "world_size") || {
        echo -e "${RED}错误: 获取world_size失败${NC}"
        exit 1
    } 
    # 修改模型权重路径config权限
    config_file="$model_path/config.json"
    if [ -f "$config_file" ]; then
        echo -e "${BLUE}修改模型配置文件权限: $config_file${NC}"
        chown -R root:root $model_path
        chmod -R 640 $model_path
        chmod 750 "$config_file"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}配置文件权限修改成功${NC}"
        else
            echo -e "${RED}警告: 配置文件权限修改失败${NC}"
        fi
    else
        echo -e "${RED}警告: 未找到模型配置文件: $config_file${NC}"
    fi
    
    if [ "$current_ip" = "$master_ip" ]; then
        echo -e "${BLUE}当前机器是主节点 ($current_ip)${NC}"
        echo -e "${BLUE}注意: 主节点应该最先启动服务${NC}"
    else
        echo -e "${BLUE}当前机器是从节点 ($current_ip)${NC}"
        echo -e "${BLUE}注意: 请确保主节点 ($master_ip) 已经启动服务${NC}"
    fi

    # 修改rank_table_file.json权限
    chmod 640 /usr/local/Ascend/mindie/latest/mindie-service/rank_table_file.json
    
    # 检查 transformers 版本
    echo -e "${BLUE}检查 transformers 版本兼容性...${NC}"
    generation_config="$model_path/generation_config.json"
    if [ -f "$generation_config" ]; then
        # 获取配置文件中的版本
        config_version=$(python3 -c '
import json
with open("'"$generation_config"'") as f:
    config = json.load(f)
print(config.get("transformers_version", ""))
')
        # 获取当前环境的版本
        current_version=$(python3 -c '
import transformers
print(transformers.__version__)
')
        
        if [ ! -z "$config_version" ] && [ "$config_version" != "$current_version" ]; then
            echo -e "${BLUE}发现版本不匹配:${NC}"
            echo -e "  配置文件版本: $config_version"
            echo -e "  当前环境版本: $current_version"
            
            read -p "是否安装配置文件指定的 transformers 版本 ($config_version)? (y/n): " yn
            case $yn in
                [Yy]* )
                    echo -e "${BLUE}正在安装 transformers=$config_version...${NC}"
                    if pip install "transformers==$config_version" -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple; then
                        echo -e "${GREEN}transformers 版本已更新为: $config_version${NC}"
                    else
                        echo -e "${RED}警告: transformers 版本安装失败${NC}"
                        echo -e "${BLUE}您可以稍后手动安装:${NC}"
                        echo -e "pip install transformers==$config_version"
                    fi
                    ;;
                [Nn]* )
                    echo -e "${BLUE}保持当前环境版本${NC}"
                    echo -e "${BLUE}如需手动安装，请执行:${NC}"
                    echo -e "pip install transformers==$config_version"
                    ;;
                * )
                    echo "请输入 y 或 n"
                    ;;
            esac
        else
            echo -e "${GREEN}transformers 版本匹配，无需调整${NC}"
        fi
    else
        echo -e "${BLUE}未找到 generation_config.json 文件，跳过版本检查${NC}"
    fi
    
    # 询问是否启动服务
    while true; do
        read -p "请确保启动服务前所有节点已运行到这一步。是否现在启动服务? (y/n): " yn
        case $yn in
            [Yy]* )
                echo -e "${BLUE}正在启动服务...${NC}"

                if [ -z "$ASCEND_RT_VISIBLE_DEVICES" ]; then
                    echo -e "${RED}~/.bashrc未正确加载，请进入容器手动启动服务${NC}"
                    echo -e "cd /usr/local/Ascend/mindie/latest/mindie-service/"
                    echo -e "nohup ./bin/mindieservice_daemon > output_\$(date +\"%Y%m%d%H%M\").log 2>&1 &"
                else
                    echo -e "${GREEN}~/.bashrc已正确加载 ${NC}"
                fi

                cd /usr/local/Ascend/mindie/latest/mindie-service/
                nohup ./bin/mindieservice_daemon > output_$(date +"%Y%m%d%H%M").log 2>&1 &
                
                # 等待服务启动
                sleep 5
                if ps aux | grep -v grep | grep mindieservice_daemon > /dev/null; then
                    echo -e "${GREEN}服务已成功启动${NC}"
                else
                    echo -e "${RED}警告: 服务可能未正常启动，请检查日志${NC}"
                fi
                cd -
                break;;
            [Nn]* )
                echo -e "${BLUE}跳过服务启动${NC}"
                echo -e "${BLUE}您可以稍后手动启动服务:${NC}"
                echo -e "cd /usr/local/Ascend/mindie/latest/mindie-service/"
                echo -e "nohup ./bin/mindieservice_daemon > output_\$(date +\"%Y%m%d%H%M\").log 2>&1 &"
                break;;
            * )
                echo "请输入 y 或 n";;
        esac
    done
    
    echo -e "\n${GREEN}部署完成!${NC}"
    if [ "$current_ip" = "$master_ip" ]; then
        echo -e "${BLUE}提示: 主节点服务启动后，请在1分钟内启动所有从节点服务${NC}"
    else
        echo -e "${BLUE}提示: 从节点服务应该在主节点服务启动后1分钟内启动${NC}"
    fi
    echo -e "${BLUE}请检查各个步骤的输出确保部署成功${NC}"
}

# 主函数
main() {
    # 设置错误处理
    set -e
    trap 'cleanup_and_exit $? "执行过程中发生错误"' ERR
    
    echo -e "${BLUE}=== NPU自动化部署工具 ===${NC}"
    world_size=$(read_config "world_size")
    

    if [ "$1" = "--in-container" ]; then
        check_files || cleanup_and_exit 1 "必要文件检查失败"
        deploy_in_container
    elif [ "$1" = "--start-service" ]; then
        start_service
    elif [ "$1" = "--cleanup" ]; then
        cleanup_previous_container
        exit 0
    else
        # 根据world_size判断部署流程
        if [ "$world_size" -lt 9 ]; then
            echo -e "${BLUE}检测到 world_size <= 8，将执行单机部署流程${NC}"
            
            check_dependencies || cleanup_and_exit 1 "依赖检查失败"
            validate_config || cleanup_and_exit 1 "配置验证失败"
            
            # 1. 读取配置文件
            echo -e "\n${GREEN}[1/5] 读取配置信息...${NC}"
            container_ip=$(read_config "container_ip")
            model_name=$(read_config "model_name")
            model_path=$(read_config "model_path")
            world_size=$(read_config "world_size")
            
            if [ -z "$container_ip" ] || [ -z "$model_name" ] || [ -z "$model_path" ] || [ -z "$world_size" ]; then
                echo -e "${RED}错误: 配置文件缺少必要字段${NC}"
                exit 1
            fi
            
            echo -e "${BLUE}配置信息:${NC}"
            echo -e "  容器IP: $container_ip"
            echo -e "  模型名称: $model_name"
            echo -e "  模型路径: $model_path"
            echo -e "  设备数量: $world_size"
            
            # 2. 启动Docker容器
            echo -e "\n${GREEN}[2/5] 启动Docker容器...${NC}"
            
            # 清理之前的容器
            cleanup_previous_container || cleanup_and_exit 1 "清理之前的容器失败"
            
            # 从配置文件获取Docker相关配置
            image=$(read_config "docker.image")
            volumes_json=$(read_config "docker.volumes")
            container_name="npu_deploy_$(date +%s)"
            
            # 构建volumes参数
            volumes_args=""
            while IFS="=" read -r host_path container_path; do
                if [ ! -z "$host_path" ] && [ ! -z "$container_path" ]; then
                    volumes_args="$volumes_args -v $host_path:$container_path"
                fi
            done <<< "$volumes_json"
            
            # 根据world_size生成device_ids
            device_ids=$(read_config "device_ids")
            
            # 启动容器
            chmod a+x lib/start_docker_single_node.sh
            ./lib/start_docker_single_node.sh "$container_name" "$image" "$volumes_args" "$device_ids" || cleanup_and_exit 1 "Docker容器启动失败"
            
            # 记录容器名称到缓存文件
            echo "$container_name" > "$CONTAINER_CACHE"
            
            echo -e "${GREEN}容器启动成功: $container_name${NC}"
            
            # 在容器中创建工作目录
            echo -e "${BLUE}创建容器工作目录...${NC}"
            docker exec "$container_name" mkdir -p /workspace
            docker exec "$container_name" mkdir -p /usr/local/Ascend/mindie/latest/mindie-service/
            
            # 复制必要文件到容器
            echo -e "${BLUE}复制配置文件到容器...${NC}"
            docker cp "$CONFIG_FILE" "$container_name:/workspace/"
            docker cp . "$container_name:/workspace/"
            
            # 3. 配置环境变量
            echo -e "\n${GREEN}[3/5] 配置环境变量...${NC}"
            docker exec "$container_name" bash -c "cd /workspace && chmod +x lib/add_env_settings_single_node.sh && ./lib/add_env_settings_single_node.sh '$container_ip' '$container_ip' '$world_size'" || cleanup_and_exit 1 "环境变量配置失败"
            
            # 4. 修改Mindie服务配置
            echo -e "\n${GREEN}[4/5] 修改Mindie服务配置...${NC}"
            docker exec "$container_name" bash -c "cd /workspace && python3 lib/modify_mindie_config_single_node.py --container-ip '$container_ip' --model-name '$model_name' --model-path '$model_path' --world-size '$world_size' --device-ids '$device_ids'" || cleanup_and_exit 1 "Mindie服务配置修改失败"
            
            # 5. 启动服务
            echo -e "\n${GREEN}[5/5] 启动服务...${NC}"
            
            # 修改模型权重路径config权限
            docker exec "$container_name" bash -c "chmod -R 640 $model_path"
            docker exec "$container_name" bash -c "[ -f '$model_path/config.json' ] && chmod 750 '$model_path/config.json'"
            
            # 检查 transformers 版本
            echo -e "${BLUE}检查 transformers 版本兼容性...${NC}"
            docker exec "$container_name" bash -c "
                generation_config=\"$model_path/generation_config.json\"
                if [ -f \"\$generation_config\" ]; then
                    # 获取配置文件中的版本
                    config_version=\$(python3 -c '
import json
with open(\"'\$generation_config'\") as f:
    config = json.load(f)
print(config.get(\"transformers_version\", \"\"))
')
                    # 获取当前环境的版本
                    current_version=\$(python3 -c '
import transformers
print(transformers.__version__)
')
                    
                    if [ ! -z \"\$config_version\" ] && [ \"\$config_version\" != \"\$current_version\" ]; then
                        echo -e \"${BLUE}发现版本不匹配:${NC}\"
                        echo -e \"  配置文件版本: \$config_version\"
                        echo -e \"  当前环境版本: \$current_version\"
                        
                        read -p \"是否安装配置文件指定的 transformers 版本 (\$config_version)? (y/n): \" yn
                        case \$yn in
                            [Yy]* )
                                echo -e \"${BLUE}正在安装 transformers=\$config_version...${NC}\"
                                if pip install \"transformers==\$config_version\" -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple; then
                                    echo -e \"${GREEN}transformers 版本已更新为: \$config_version${NC}\"
                                else
                                    echo -e \"${RED}警告: transformers 版本安装失败${NC}\"
                                    echo -e \"${BLUE}您可以稍后手动安装:${NC}\"
                                    echo -e \"pip install transformers==\$config_version\"
                                fi
                                ;;
                            [Nn]* )
                                echo -e \"${BLUE}保持当前环境版本${NC}\"
                                echo -e \"${BLUE}如需手动安装，请执行:${NC}\"
                                echo -e \"pip install transformers==\$config_version\"
                                ;;
                            * )
                                echo \"请输入 y 或 n\"
                                ;;
                        esac
                    else
                        echo -e \"${GREEN}transformers 版本匹配，无需调整${NC}\"
                    fi
                else
                    echo -e \"${BLUE}未找到 generation_config.json 文件，跳过版本检查${NC}\"
                fi
            "
            
            # 询问是否启动服务
            while true; do
                read -p "是否现在启动服务? (y/n): " yn
                case $yn in
                    [Yy]* )
                        echo -e "${BLUE}正在启动服务...${NC}"
                        docker exec "$container_name" bash -c "cd /usr/local/Ascend/mindie/latest/mindie-service/ && nohup ./bin/mindieservice_daemon > output_\$(date +\"%Y%m%d%H%M\").log 2>&1 &"
                        
                        # 等待服务启动
                        sleep 10
                        if docker exec "$container_name" bash -c "ps aux | grep -v grep | grep mindieservice_daemon > /dev/null"; then
                            echo -e "${GREEN}服务已成功启动${NC}"
                        else
                            echo -e "${RED}警告: 服务可能未正常启动，请检查日志${NC}"
                        fi
                        break;;
                    [Nn]* )
                        echo -e "${BLUE}跳过服务启动${NC}"
                        echo -e "${BLUE}您可以稍后手动启动服务:${NC}"
                        echo -e "docker exec -it $container_name bash"
                        echo -e "cd /usr/local/Ascend/mindie/latest/mindie-service/"
                        echo -e "nohup ./bin/mindieservice_daemon > output_\$(date +\"%Y%m%d%H%M\").log 2>&1 &"
                        break;;
                    * )
                        echo "请输入 y 或 n";;
                esac
            done
            
            echo -e "\n${GREEN}单机部署完成!${NC}"
            echo -e "${BLUE}请检查各个步骤的输出确保部署成功${NC}"
            
        else
            echo -e "${BLUE}检测到 world_size > 8，执行多机部署流程${NC}"
        
            check_dependencies || cleanup_and_exit 1 "依赖检查失败"
            validate_config || cleanup_and_exit 1 "配置验证失败"
            
            # 1. 执行网络检查
            echo -e "\n${GREEN}[1/8] 执行网络环境检查...${NC}"
            chmod a+x lib/auto_check.sh
            ./lib/auto_check.sh || cleanup_and_exit 1 "网络检查失败"
            
            # 2. 安装依赖并生成rank表
            echo -e "\n${GREEN}[2/8] 生成rank表配置...${NC}"
            
            # Python和pip检查
            command -v python3 >/dev/null 2>&1 || cleanup_and_exit 1 "未找到python3命令"
            command -v pip3 >/dev/null 2>&1 || cleanup_and_exit 1 "未找到pip3命令"
            
            # 安装paramiko
            echo -e "${BLUE}安装SSH连接所需的paramiko库...${NC}"
            pip3 install resources/paramiko-3.5.1-py3-none-any.whl --find-links=./resources --no-index || cleanup_and_exit 1 "paramiko安装失败"
            
            # 从配置文件获取节点信息和SSH配置
            nodes=$(read_config "nodes")
            username=$(read_config "ssh.username")
            use_key=$(read_config "ssh.use_key")
            key_path=$(read_config "ssh.key_path")
            password=$(read_config "ssh.password")
            ssh_port=$(read_config "ssh.port")

            # 构建命令行参数
            # 移除最后一个换行符，然后转换换行为逗号
            nodes=$(echo "$nodes" | sed '/^$/d' | tr '\n' ',')
            # 移除最后一个逗号（如果存在）
            nodes=${nodes%,}
            cmd="python3 lib/generate_ranktable.py --nodes '$nodes' --username $username"
            
            # 添加端口参数
            if [ "$ssh_port" != "null" ]; then
                cmd="$cmd --port $ssh_port"
            fi

            if [ "$use_key" = "true" ]; then
                cmd="$cmd --use-key"
                # 如果指定了密钥路径，确保它存在
                if [ ! -z "$key_path" ] && [ "$key_path" != "null" ]; then
                    key_path=$(eval echo "$key_path")  # 展开路径中的~
                    if [ ! -f "$key_path" ]; then
                        echo -e "${RED}错误: SSH密钥文件不存在: $key_path${NC}"
                        exit 1
                    fi
                fi
            else
                if [ -z "$password" ] || [ "$password" = "null" ]; then
                    echo -e "${RED}错误: 未使用SSH密钥但未提供密码${NC}"
                    exit 1
                fi
                cmd="$cmd --password $password"
            fi

            # 执行rank表生成
            eval "$cmd" || cleanup_and_exit 1 "rank表生成失败"
            
            # 3. 启动Docker容器
            echo -e "\n${GREEN}[3/8] 启动Docker容器...${NC}"
            start_docker_and_deploy || cleanup_and_exit 1 "Docker容器启动或部署失败"
        fi
    fi
}

# 执行主函数
main "$@" 