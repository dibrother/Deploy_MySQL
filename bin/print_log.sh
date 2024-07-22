# 输出打印
__CEND='\033[0m';
__CRED='\033[0;31m';
__CGREEN='\033[0;32m';
__CYELLOW='\033[0;33m';

print_info(){
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${__CGREEN}[INFO]${__CEND} $1"
}

print_warning(){
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${__CYELLOW}[WARNING]${__CEND} $1"
}

print_error(){
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${__CRED}[ERROR]${__CEND} $1"
}