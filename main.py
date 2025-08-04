# main_controller.py (版本 5.0 - 结合shell方案)

import pyperclip
import platform
import requests
import time
import json
import os
import random
import csv
import pyotp
import re
import threading
from concurrent.futures import ThreadPoolExecutor
from selenium import webdriver
from selenium.webdriver.chrome.options import Options as ChromeOptions
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, NoSuchElementException, WebDriverException, ElementNotInteractableException
from webdriver_manager.chrome import ChromeDriverManager
from selenium.webdriver.common.keys import Keys 


# --- 全局配置 ---
ADSPOWER_API_URL = "http://127.0.0.1:50325"
MAX_PROXY_USAGE = 2
PROXY_USAGE_FILE = "proxy_usage.json"
ACCOUNTS_FILE = "accounts.csv"
DOWNLOAD_DIR = os.path.join(os.getcwd(), "gcp_downloads")

# 将固定的UA修改为模板和基础版本号，方便后续动态构建
CHROME_MAJOR_VERSION = "138"
CHROME_BUILD_BASE = "7204"
USER_AGENT_TEMPLATE = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/{}.0.{}.{} Safari/537.36"
)

screen_width = 2560
num_windows_to_tile = 15
y_position = 0
x_overlap_offset = 50
 
# 2. 计算每个窗口的水平间隔
step = (screen_width - x_overlap_offset * (num_windows_to_tile - 1)) // num_windows_to_tile
# 如果希望窗口紧凑排列，可以使用更简单的 step = screen_width // num_windows_to_tile
if step < x_overlap_offset:
    step = x_overlap_offset
 
# 3. 动态生成窗口位置配置 (只包含 x 和 y)
WINDOW_CONFIGS = []
for i in range(num_windows_to_tile):
    pos_x = i * step
    
    # 防止窗口完全跑出屏幕右侧，可以加一个简单的边界检查
    if pos_x > screen_width - 200: # 假设窗口至少有200像素可见
        pos_x = screen_width - 200
        
    WINDOW_CONFIGS.append({
        'x': pos_x,
        'y': y_position
        # 注意：这里我们故意不包含 'width' 和 'height'
    })


class LayoutPoolManager:
    """
    一个线程安全的状态化窗口布局池管理器。
    它确保每个窗口布局在同一时间只被一个线程使用。
    """
    def __init__(self, layout_configs: list):
        self._lock = threading.Lock()
        # 将原始配置列表转换为带状态的对象池
        self.pool = [{'layout': config, 'state': 'unused'} for config in layout_configs]
        print(f"布局池管理器已初始化，包含 {len(self.pool)} 个可用布局。")
 
    def acquire(self) -> dict:
        """
        请求并获取一个未使用的窗口布局。
        如果当前没有可用布局，此方法将阻塞并等待，直到有布局被释放。
        返回: 获得的布局字典 (e.g., {'x': 0, 'y': 0, ...})
        """
        while True:
            with self._lock:
                for item in self.pool:
                    if item['state'] == 'unused':
                        item['state'] = 'in_use'
                        return item['layout']
            
            # 如果循环走完都没找到，说明池已满。
            time.sleep(0.5)
 
    def release(self, layout_to_release: dict):
        """
        将一个使用完毕的窗口布局归还到池中。
        """
        with self._lock:
            # 遍历池，找到匹配的布局并将其状态改回未使用
            for item in self.pool:
                if item['layout'] == layout_to_release:
                    item['state'] = 'unused'
                    break



# process_single_account 的最终版本
def process_single_account(account: dict, layout_manager: LayoutPoolManager, available_proxies: list, usage_data: dict, usage_lock: threading.Lock) -> dict:
    """
    这是一个线程安全且使用对象池的工作单元，负责处理单个账户的完整生命周期。
    它会主动从布局管理器中请求(acquire)和释放(release)窗口布局。
    """
    # 初始化
    layout_config = None
    log_func = None
    new_profile_id = None
    proxy_id_to_use = None
    result_status = "Failed: Initialization"

    # logger的打印函数
    pre_log_prefix = f"[{account['username'].split('@')[0]:<18}]"
    def pre_log(message: str):
        print(f"{pre_log_prefix} {message}")

    try:
        # 从池中获取窗口布局
        pre_log("正在等待并请求窗口布局...")
        layout_config = layout_manager.acquire()
        
        # 创建专属记录器
        def create_logger(message: str):
            print(f"{pre_log_prefix} {message}")
        log_func = create_logger
        
        log_func("--- 线程任务启动，已成功获取窗口布局 ---")

        # 使用线程锁来保护对共享资源
        with usage_lock:
            proxy_id_to_use = select_available_proxy(available_proxies, usage_data, log_func)
            usage_data[proxy_id_to_use] = usage_data.get(proxy_id_to_use, 0) + 1
            log_func(f"已锁定并分配代理 {proxy_id_to_use} (当前使用次数: {usage_data[proxy_id_to_use]})")

        profile_name = f"profile_{account['username'].split('@')[0]}_{random.randint(100, 999)}"
        new_profile_id = create_ads_profile(profile_name, proxy_id_to_use)
        log_func(f"已创建 Profile ID: {new_profile_id}")
        
        browser_data = start_browser_profile(new_profile_id, headless=False)
        # 将获取到的布局配置传递给下一层
        result_status = run_automation_flow_adspower(browser_data, account, log_func, layout_config)
        
        # 如果自动化流程不成功，则回滚代理使用次数
        if "Success" not in result_status and "Unsupported" not in result_status:
            with usage_lock:
                if usage_data.get(proxy_id_to_use, 0) > 0:
                    usage_data[proxy_id_to_use] -= 1
                    log_func(f"任务失败，已回滚代理 {proxy_id_to_use} 的使用次数 (回滚后: {usage_data.get(proxy_id_to_use, 0)})")

    except Exception as e:
        # 捕获异常
        (log_func or pre_log)(f"[线程致命错误] 发生未捕获的异常: {e}")
        import traceback
        traceback.print_exc()
        result_status = f"Failed: Worker Thread Critical Error - {e}"
        
        # 异常回滚
        if proxy_id_to_use and usage_data.get(proxy_id_to_use, 0) > 0:
            with usage_lock:
                usage_data[proxy_id_to_use] -= 1
                (log_func or pre_log)(f"因异常已回滚代理 {proxy_id_to_use} 的使用次数。")
    
    finally:
        # 关闭浏览器
        if new_profile_id:
            close_browser(new_profile_id, (log_func or pre_log))
        
        # 将窗口布局归还到池中
        if layout_config:
            (log_func or pre_log)("正在将窗口布局归还到池中...")
            layout_manager.release(layout_config)
            (log_func or pre_log)("  - [成功] 布局已归还，可供其他线程使用。")

        (log_func or pre_log)(f"--- 线程任务结束，最终状态: {result_status} ---\n")

    return {"account": account['username'], "status": result_status}


# 函数 1, 2, 3 (代理部分)
def load_proxy_usage():
    if not os.path.exists(PROXY_USAGE_FILE): return {}
    try:
        with open(PROXY_USAGE_FILE, 'r') as f: return json.load(f)
    except (json.JSONDecodeError, IOError):
        print(f"警告: {PROXY_USAGE_FILE} 文件无法解析，将作为空记录处理。")
        return {}

def save_proxy_usage(data: dict):
    with open(PROXY_USAGE_FILE, 'w') as f:
        json.dump(data, f, indent=4)

def get_all_proxies_from_manager() -> list:
    list_url = f"{ADSPOWER_API_URL}/api/v2/proxy-list/list"
    all_proxies, page = [], 1
    print("正在连接AdsPower API，获取代理列表...")
    while True:
        try:
            response = requests.post(list_url, json={"page": page, "limit": 200}, timeout=20)
            response.raise_for_status()
            resp_json = response.json()
            if resp_json.get("code") != 0:
                raise ConnectionError(f"API获取代理列表失败: {resp_json.get('msg')}")
            proxies_on_page = resp_json.get("data", {}).get("list", [])
            if not proxies_on_page: break
            all_proxies.extend(proxies_on_page)
            print(f"  - 已获取第 {page} 页，共 {len(proxies_on_page)} 个代理。")
            if len(proxies_on_page) < 200: break
            page += 1
        except requests.exceptions.RequestException as e:
            raise ConnectionError(f"连接AdsPower V2 API时发生网络错误: {e}")
    print(f"代理列表获取完毕，总共 {len(all_proxies)} 个代理。")
    return all_proxies

def select_available_proxy(proxies: list, usage: dict, log_func=print) -> str:
    eligible = [p.get("proxy_id") for p in proxies if p.get("proxy_id") and usage.get(p.get("proxy_id"), 0) < MAX_PROXY_USAGE]
    if not eligible:
        raise Exception("所有可用代理均已达到使用上限！请补充代理或重置记录。")
    selected = random.choice(eligible)
    log_func(f"筛选完毕，随机选择可用代理ID: {selected}")
    return selected



# 函数 4, 5 (浏览器 Profile 创建与启动)
def create_ads_profile(username: str, proxy_id: str) -> str:
    print(f"准备创建配置文件 [{username}]...")
    create_url = f"{ADSPOWER_API_URL}/api/v1/user/create"
    random_patch_version = random.randint(10, 105)
    dynamic_user_agent = USER_AGENT_TEMPLATE.format(CHROME_MAJOR_VERSION, CHROME_BUILD_BASE, random_patch_version)
    print(f"动态生成的 User-Agent: {dynamic_user_agent}")
    
    # 添加下载设置
    chrome_preferences = {
        "download.default_directory": DOWNLOAD_DIR,
        "download.prompt_for_download": False,
        "download.directory_upgrade": True,
        "safebrowsing.enabled": True
    }
    
    payload = {
        "name": username, "group_id": "0", "proxyid": proxy_id,
        "fingerprint_config": {
            "browser_kernel_config": {"version": CHROME_MAJOR_VERSION, "type": "chrome"},
            "ua": dynamic_user_agent, "webrtc": "disabled", "automatic_timezone": "1"
        },
        "chrome_preferences": chrome_preferences # <-- 添加到 payload
    }
    try:
        response = requests.post(create_url, json=payload, timeout=30)
        response.raise_for_status()
        resp_json = response.json()
        if resp_json.get("code") == 0 and resp_json.get("data", {}).get("id"):
            return resp_json["data"]["id"]
        else:
            raise ConnectionError(f"API 创建 Profile 失败: {resp_json.get('msg', '未知错误')}")
    except requests.exceptions.RequestException as e:
        raise ConnectionError(f"连接 AdsPower 创建API时发生网络错误: {e}")

def start_browser_profile(profile_id: str, headless: bool = False) -> dict:
    print(f"准备启动浏览器 Profile ID: {profile_id}...")
    start_url = f"{ADSPOWER_API_URL}/api/v1/browser/start"
    params = {"user_id": profile_id, "open_tabs": 1}
    if headless: params["headless"] = 1
    
    
    try:
        response = requests.get(start_url, params=params, timeout=90)
        response.raise_for_status()
        resp_json = response.json()
        if resp_json.get("code") == 0 and "data" in resp_json:
            print("[成功] 浏览器启动成功！")
            return resp_json["data"]
        else:
            raise ConnectionError(f"API 启动浏览器失败: {resp_json.get('msg', '未知错误')}")
    except requests.exceptions.RequestException as e:
        raise ConnectionError(f"连接 AdsPower 启动API时发生网络错误: {e}")

def close_browser(profile_id: str, log_func=print):
    """通过API关闭指定ID的浏览器。"""
    log_func(f"准备通过 API 关闭浏览器 Profile ID: {profile_id}...")
    close_url = f"{ADSPOWER_API_URL}/api/v1/browser/stop"
    params = {"user_id": profile_id}
    try:
        response = requests.get(close_url, params=params, timeout=30)
        response.raise_for_status()
        resp_json = response.json()
        if resp_json.get("code") == 0:
            log_func(f"  - [成功] API 已发送关闭指令。")
        else:
            log_func(f"  - [警告] API 关闭浏览器失败: {resp_json.get('msg', '未知错误')}")
    except requests.exceptions.RequestException as e:
        log_func(f"  - [警告] 连接 AdsPower 关闭API时发生网络错误: {e}")


# =================================================================
# 函数 6: 自动化执行部分
# =================================================================
def classify_recovery_data(recovery_data: str) -> tuple[str | None, str]:
    if not recovery_data or not recovery_data.strip(): return None, ""
    data = recovery_data.strip()
    if '@' in data and '.' in data.split('@')[1]: return "email", data
    cleaned_key = re.sub(r'\s+', '', data)
    if re.match(r'^[A-Za-z2-7]+$', cleaned_key): return "2fa_totp", cleaned_key
    if re.match(r'^[A-Za-z0-9\s]+$', data): return "2fa_totp", cleaned_key
    return None, data

def handle_recovery_email(driver: webdriver.Chrome, wait: WebDriverWait, recovery_email: str, log_func) -> bool:
    try:
        email_input = wait.until(EC.visibility_of_element_located((By.XPATH, "//input[@type='email' or @name='knowledgePreregisteredEmailResponse']")))
        email_input.send_keys(recovery_email)
        driver.find_element(By.XPATH, "//*[text()='Next' or text()='下一步']/ancestor::button").click()
        return True
    except: return False

def handle_2fa_totp(driver: webdriver.Chrome, wait: WebDriverWait, totp_key: str, log_func) -> bool:
    log_func("--- [2FA流程] 开始处理TOTP验证 ---")
 
    try:
        totp_code = pyotp.TOTP(totp_key).now()
        log_func(f"  - 生成了TOTP验证码: {totp_code}")
 
        input_box_xpath = "//input[@id='totpPin' or @name='Pin']"
        input_box = wait.until(EC.visibility_of_element_located((By.XPATH, input_box_xpath)))
        
        input_box.clear()
        input_box.send_keys(totp_code)
        log_func("  - [成功] 已输入验证码。")
 
    except TimeoutException:
        log_func("  - [错误] 定位2FA验证码输入框超时。请检查XPath是否正确。")
        return False
    except Exception as e:
        log_func(f"  - [错误] 在输入验证码时发生未知错误: {e}")
        return False
 
    try:
        next_button_selector = "button.nCP5yc[jsname='LgbsSe']"
        next_button = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, next_button_selector)))
        
        try:
            next_button.click()
        except ElementNotInteractableException:
            log_func("  - [警告] 常规点击失败，尝试使用JavaScript强制点击。")
            driver.execute_script("arguments[0].click();", next_button)
            
        log_func("  - [成功] 已点击'下一步'按钮。")
        log_func("--- [2FA流程] TOTP验证已提交 ---")
        return True
 
    except TimeoutException:
        log_func("  - [错误] 定位或等待'下一步'按钮可点击时超时。")
        log_func(f"    使用的选择器是: '{next_button_selector}'")
        return False
    except Exception as e:
        log_func(f"  - [错误] 点击'下一步'按钮时发生未知错误: {e}")
        return False


def automate_google_login(driver: webdriver.Chrome, account: dict, log_func) -> str:
    """执行Google登录，并动态处理验证环节。"""
    email, password, recovery_data = account['username'], account['password'], account['recovery_data']
    wait = WebDriverWait(driver, 15)

    try:
        log_func(f"\n--- 正在尝试登录账户: {email} ---")
        driver.get("https://accounts.google.com/signin")

        wait.until(EC.visibility_of_element_located((By.ID, "identifierId"))).send_keys(email)
        wait.until(EC.element_to_be_clickable((By.ID, "identifierNext"))).click()
        
        time.sleep(random.uniform(1.5, 3))
        
        password_input = wait.until(EC.visibility_of_element_located((By.NAME, "Passwd")))
        log_func(f"\n--- 正在输入密码 ---")
        password_input.send_keys(password)
        wait.until(EC.element_to_be_clickable((By.ID, "passwordNext"))).click()
        
        end_time = time.time() + 45
        while time.time() < end_time:
            time.sleep(2)
            current_url, page_source = driver.current_url, driver.page_source
            
            try:
                if "/challenge/totp" in current_url or "Google Authenticator" in page_source:
                    log_func(f"\n--- 检测到2FA ---")
                    recovery_type, data = classify_recovery_data(recovery_data)
                    if recovery_type != "2fa_totp" or not handle_2fa_totp(driver, wait, data, log_func): return "Failed: 2FA Step"
                    continue
                if "recovery email" in page_source or "辅助邮箱" in page_source:
                    recovery_type, data = classify_recovery_data(recovery_data)
                    if recovery_type != "email" or not handle_recovery_email(driver, wait, data, log_func): return "Failed: Recovery Email Step"
                    continue
                if "Wrong password" in page_source or "密码不正确" in page_source: return "Failed: Wrong Password"
                if "Check your phone" in page_source or "在手机上" in page_source: return "Unsupported: Phone Verification"
            except NoSuchElementException: pass

            if "myaccount.google.com" in current_url or "accounts.google.com/SignOutOptions" in page_source: return "Success"
            if "/signin/" not in current_url and "/challenge/" not in current_url: return "Success"

        screenshot_path = f"error_unknown_state_{email.split('@')[0]}.png"
        driver.save_screenshot(screenshot_path)
        return f"Failed: Timed out (Screenshot: {screenshot_path})"

    except Exception as e:
        screenshot_path = f"error_critical_{email.split('@')[0]}.png"
        try: driver.save_screenshot(screenshot_path)
        except: pass
        return f"Failed: Critical Error ({type(e).__name__}, Screenshot: {screenshot_path})"


# =================================================================
# 状态机辅助函数
# =================================================================
def attempt_action(driver: webdriver, timeout: int, action_type: str, xpath: str, keys_to_send=None) -> bool:
    try:
        wait = WebDriverWait(driver, timeout)
        if action_type == 'click':
            element = wait.until(EC.element_to_be_clickable((By.XPATH, xpath)))
            element.click()
        elif action_type == 'send_keys':
            element = wait.until(EC.visibility_of_element_located((By.XPATH, xpath)))
            element.send_keys(keys_to_send)
        elif action_type == 'check_presence':
            wait.until(EC.presence_of_element_located((By.XPATH, xpath)))
        else:
            return False
        return True
    except TimeoutException:
        return False

# =================================================================
# 函数: 在 Cloud Shell 中执行脚本
# =================================================================
def execute_script_in_cloud_shell_resilient(driver: webdriver.Chrome, account: dict, log_func) -> tuple[bool, str]:
 
    email_prefix = account['username'].split('@')[0]
    
    # 定义工作流
    class WorkflowStep:
        START = 0
        CLICK_SHELL_BUTTON = 1
        ENTER_SHELL_AND_PREPARE_TERMINAL = 2
        SEND_BASH_COMMAND = 3
        WAIT_FOR_SIGNAL_AND_MONITOR = 4
        CLICK_MORE_MENU = 5
        CLICK_DOWNLOAD_MENU = 6
        CLICK_FINAL_DOWNLOAD = 7
        WAIT_FOR_UI_CONFIRMATION = 8
 
    current_step = WorkflowStep.START
    MASTER_TIMEOUT = 900
    end_time = time.time() + MASTER_TIMEOUT
    
    COMPLETION_SIGNAL = "PYTHON_AUTOMATION_TASK_COMPLETE"
    BASH_COMMAND = (
        "curl -sL https://raw.githubusercontent.com/smysle/A/refs/heads/main/mo.sh -o mo.sh && "
        "chmod +x mo.sh && "
        "export PS1=$ && export TERM=xterm && "
        "script -q -c 'bash mo.sh' <<< $'2\\ny\\n1\\n3\\nvertex\\ny\\n0'; "
        f"echo '{COMPLETION_SIGNAL}'"
    )

    def handle_connection_issues():
        """
        在iframe内检查并处理连接断开的问题。
        """
        try:
            # 使用非常短的超时来快速检查，避免阻塞主流程
            reconnect_button = WebDriverWait(driver, 1).until(
                EC.element_to_be_clickable((By.XPATH, "//button[contains(., 'Reconnect')]"))
            )
            log_func("\n  🛡️ [守护进程] 检测到连接已断开，正在尝试点击'Reconnect'...")
            reconnect_button.click()
            log_func("  🛡️ [守护进程] 已点击'Reconnect'，等待终端重新连接（最多30秒）...")
            
            # 等待终端输入框重新出现，作为连接成功的标志
            WebDriverWait(driver, 30).until(
                EC.presence_of_element_located((By.CLASS_NAME, "xterm-helper-textarea"))
            )
            log_func("  🛡️ [守护进程] 终端已重新连接！主流程可以继续。\n")
            return True # 返回True表示处理了连接问题
            
        except TimeoutException:
            return False # 没有找到Reconnect按钮，一切正常
        except Exception as e:
            log_func(f"\n  🛡️ [守护进程] 在处理重连时发生未知错误: {e}\n")
            return False
 
    log_func("\n--- 启动cloud shell状态流程 ---")
 
    iframe_switched = False
 
    while time.time() < end_time:

        if iframe_switched:
            handle_connection_issues()
        
        if current_step == WorkflowStep.START:
            log_func("[状态] -> START: 流程开始")
            current_step = WorkflowStep.CLICK_SHELL_BUTTON
 
        elif current_step == WorkflowStep.CLICK_SHELL_BUTTON:
            if attempt_action(driver, 10, 'click', "//button[contains(@aria-label, 'Activate Cloud Shell')]"):
                log_func("[状态] -> CLICK_SHELL_BUTTON: [成功] 点击了Cloud Shell按钮。")
                current_step = WorkflowStep.ENTER_SHELL_AND_PREPARE_TERMINAL
                time.sleep(2)
            
        elif current_step == WorkflowStep.ENTER_SHELL_AND_PREPARE_TERMINAL:
            
            # 这个阶段负责所有进入Cloud Shell的准备工作
            # 1. 切换到Iframe
            if not iframe_switched:
                try:
                    WebDriverWait(driver, 20).until(EC.frame_to_be_available_and_switch_to_it(
                        (By.XPATH, "//iframe[contains(@src, 'cloudshell')]")
                    ))
                    log_func("[状态] -> ENTER_SHELL: [成功] 切换到Cloud Shell iframe。")
                    iframe_switched = True
                except TimeoutException:
                    log_func("  - 等待Cloud Shell iframe超时，将在下一个循环重试。")
                    time.sleep(5)
                    continue
 

            log_func("  - [准备阶段] 开始检查 'Continue', 'Authorize' 弹窗并等待终端就绪（最长60秒）...")
            
            preparation_end_time = time.time() + 60
            terminal_ready = False
            
            while time.time() < preparation_end_time:
                # 检查 'Continue' 按钮
                try:
                    continue_button = WebDriverWait(driver, 1).until(EC.element_to_be_clickable(
                        (By.XPATH, "//button[.//span[normalize-space()='Continue']]")
                    ))
                    continue_button.click()
                    log_func("  - [准备阶段] 检测到并点击了 'Continue' 按钮。")
                    time.sleep(3)
                    continue
                except TimeoutException:
                    pass
 
                # 检查 'Authorize' 按钮
                try:
                    authorize_button = WebDriverWait(driver, 1).until(EC.element_to_be_clickable(
                        (By.XPATH, "//button[normalize-space()='Authorize' or .//span[normalize-space()='Authorize']]")
                    ))
                    authorize_button.click()
                    log_func("  - [准备阶段] 检测到并点击了 'Authorize' 按钮。")
                    log_func("  - 授权后，给予10秒缓冲时间进行环境配置...")
                    time.sleep(10)
                    continue
                except TimeoutException:
                    pass
 
                # 检查最终目标：终端是否就绪
                try:
                    WebDriverWait(driver, 1).until(EC.presence_of_element_located((By.CLASS_NAME, "xterm-helper-textarea")))
                    log_func("[状态] -> PREPARE_TERMINAL: [成功] 终端已准备就绪。")
                    terminal_ready = True
                    break
                except TimeoutException:
                    pass
                
                log_func(f"  - 准备中... (剩余 {(preparation_end_time - time.time()):.0f}s)")
                time.sleep(2) # 短暂休眠
 
            if terminal_ready:
                current_step = WorkflowStep.SEND_BASH_COMMAND
            else:
                log_func("  - [超时] 在60秒内终端未能准备就绪，任务可能失败。")
                time.sleep(999) 
            

        elif current_step == WorkflowStep.SEND_BASH_COMMAND:
            log_func("[状态] -> SEND_BASH_COMMAND: 准备通过剪贴板粘贴命令...")
            try:

                pyperclip.copy(BASH_COMMAND)
                log_func("  - [1/3] 命令已复制到剪贴板。")
                

                terminal_input = driver.find_element(By.CLASS_NAME, "xterm-helper-textarea")
                terminal_input.click() 
                time.sleep(0.5)
 
                paste_key = Keys.COMMAND if platform.system() == "Darwin" else Keys.CONTROL
                terminal_input.send_keys(paste_key, 'v')
                log_func("  - [2/3] 已模拟粘贴操作 (Ctrl/Cmd+V)。")
                time.sleep(1)
 

                terminal_input.send_keys(Keys.RETURN)
                log_func("  - [3/3] 已发送回车执行。")
                
                log_func("  - [成功] 已通过粘贴方式发送Bash命令。")
                current_step = WorkflowStep.WAIT_FOR_SIGNAL_AND_MONITOR
 
            except Exception as e:
                log_func(f"  - [错误] 发送命令时发生异常: {e}")
                time.sleep(5)
                pass
                
        
        elif current_step == WorkflowStep.WAIT_FOR_SIGNAL_AND_MONITOR:
            log_func("[状态] -> WAIT_FOR_SIGNAL: 开始监控终端输出和连接状态（最长600秒）...")
            wait_end_time = time.time() + 600
            
            signal_found = False
            while time.time() < wait_end_time:
                try:
                    # 1. 检查断线重连按钮
                    reconnect_button = WebDriverWait(driver, 1).until(
                        EC.element_to_be_clickable((By.XPATH, "//button[contains(., 'Reconnect')]"))
                    )
                    if reconnect_button:
                        log_func("  - [监控] 检测到连接已断开，正在点击'Reconnect'...")
                        reconnect_button.click()
                        time.sleep(10)
                        WebDriverWait(driver, 30).until(EC.presence_of_element_located((By.CLASS_NAME, "xterm-helper-textarea")))
                        log_func("  - [监控] 终端已重新连接。")
                        continue
 
                except TimeoutException:

                     pass
                
                try:
                    # 2. 检查任务完成信号
                    terminal_output = driver.find_element(By.CLASS_NAME, "xterm-rows").text
                    if COMPLETION_SIGNAL in terminal_output:
                        log_func(f"  - [成功] 已检测到完成信号！")
                        signal_found = True
                        break
                except NoSuchElementException:
                    log_func("  - [监控] 无法找到终端输出区域，可能仍在加载...")
                
                # 打印等待日志
                log_func(f"  - 脚本执行中，等待信号... (剩余 {(wait_end_time - time.time()):.0f}s)")
                time.sleep(10)
            
            if signal_found:
                current_step = WorkflowStep.CLICK_MORE_MENU
            else:
                log_func("  - [超时] 在600秒内未检测到完成信号，任务可能已失败。")
                time.sleep(999)
        
        elif current_step == WorkflowStep.CLICK_MORE_MENU:
            if attempt_action(driver, 10, 'click', "//button[@aria-label='More Cloud Shell settings']"):
                log_func("[状态] -> CLICK_MORE_MENU: [成功] 点击了'More'菜单。")
                current_step = WorkflowStep.CLICK_DOWNLOAD_MENU
            else:
                log_func("  - 尝试点击'More'菜单失败，重试...")
        
        elif current_step == WorkflowStep.CLICK_DOWNLOAD_MENU:
            if attempt_action(driver, 5, 'click', "//button[.//mat-icon[text()='cloud_download']]"):
                log_func("[状态] -> CLICK_DOWNLOAD_MENU: [成功] 点击了'Download'菜单项。")
                current_step = WorkflowStep.CLICK_FINAL_DOWNLOAD
            else:
                log_func("  - 尝试点击'Download'菜单项失败，重试...")
 
        elif current_step == WorkflowStep.CLICK_FINAL_DOWNLOAD:
            if attempt_action(driver, 5, 'click', "//button[normalize-space()='Download']"):
                log_func("[状态] -> CLICK_FINAL_DOWNLOAD: [成功] 点击了最终下载按钮。")
                current_step = WorkflowStep.WAIT_FOR_UI_CONFIRMATION
            else:
                log_func("  - 尝试点击最终下载按钮失败，重试...")
 
        elif current_step == WorkflowStep.WAIT_FOR_UI_CONFIRMATION:
            log_func("[状态] -> WAIT_FOR_UI_CONFIRMATION: 等待下载成功的UI通知...")
            try:
                success_icon_xpath = "//div[contains(., 'Transferred') and contains(., 'item')]//mat-icon[contains(., 'check_circle')]"
                WebDriverWait(driver, 60).until(EC.presence_of_element_located((By.XPATH, success_icon_xpath)))
                
                log_func("  - [成功] 检测到UI上的绿色勾勾确认。")

                download_wait_seconds = 10
                log_func(f"  - [等待] 为确保文件下载完成，额外等待 {download_wait_seconds} 秒...")
                time.sleep(download_wait_seconds)
                log_func("  - [等待] 等待结束，继续执行。")
                
                driver.switch_to.default_content()
                log_func("[状态] -> SWITCH_BACK_TO_DEFAULT: [成功] 已切回主窗口。")
                

                return True, "下载成功（基于UI确认，未验证本地文件）"
 
            except TimeoutException:
                log_func("  - [超时] 等待60秒未检测到下载成功的UI通知。")
                driver.switch_to.default_content()
                return False, "下载超时（未在UI上看到确认信息）"
        
        time.sleep(2)
 
    try:
        driver.switch_to.default_content()
    except:
        pass
        
    return False, f"任务失败: 总超时({MASTER_TIMEOUT}秒)已到。流程卡在步骤: {WorkflowStep(current_step).name}"

# 全局守护函数，判断当前流程
def redetermine_login_step(driver: webdriver.Chrome) -> str:

    try:
        current_url = driver.current_url
        page_source = driver.page_source
 
        # 优先级最高的判断：是否已经登录成功？
        if "myaccount.google.com" in current_url or "accounts.google.com/SignOutOptions" in page_source:
            return "Success"
        if "/signin/" not in current_url and "/challenge/" not in current_url:
            return "Success"
            
        # 判断是否在2FA验证页面
        if "/challenge/totp" in current_url or "Google Authenticator" in page_source:
            return "State: 2FA Challenge"
 
        # 判断是否在密码输入页面
        try:
            if driver.find_element(By.NAME, "Passwd").is_displayed():
                return "State: Password Input"
        except NoSuchElementException:
            pass
 
        # 判断是否在用户名输入页面
        try:
            if driver.find_element(By.ID, "identifierId").is_displayed():
                return "State: Identifier Input"
        except NoSuchElementException:
            pass
        
        return "State: Unknown, likely on sign-in page"
 
    except Exception as e:
        return f"State: Error during redetermination - {e}"
 

# 这是一个新的、更通用的核心函数
def execute_core_automation(driver: webdriver.Chrome, account: dict, log_func) -> str:
    """
    接收一个已经准备好的driver和账户信息，执行核心的自动化任务。
    这个函数是模式无关的。
    """
    try:
        login_result = automate_google_login(driver, account, log_func)
 
        if login_result == "Success":
            log_func("  - Google 登录成功，准备执行 GCP 操作...")
            
            target_url = "https://console.cloud.google.com/billing/projects?inv=1&invt=Ab4fWA&organizationId=0"
            log_func(f"  - 主动导航到目标页面: {target_url}")
            driver.get(target_url)
            
            # 导航阶段的守护
            try:
                WebDriverWait(driver, 90).until(
                    EC.presence_of_element_located((By.XPATH, "//span[contains(text(), 'Select a project')] | //button[contains(@aria-label, 'Activate Cloud Shell')]"))
                )
                print("  - [守护] 已确认GCP页面加载成功。")
            except TimeoutException:
                return "Failed: GCP Page load timeout"
 
            log_func("  - 页面导航完成，开始在 Cloud Shell 中执行脚本...")
            gcp_success, gcp_result_msg = execute_script_in_cloud_shell_resilient(driver, account, log_func)
            
            if gcp_success:
                return f"Success: Result file at {gcp_result_msg}"
            else:
                return f"Failed: {gcp_result_msg}"
        else:
            return login_result
    except Exception as e:
        import traceback
        error_details = traceback.format_exc()
        log_func(f"[致命错误] 在核心自动化流程中发生未捕获的异常:\n{error_details}")
        return f"Failed: An unexpected error in core automation - {type(e).__name__}"
 
 
# 现在，重构原来的 run_automation_flow 函数，让它成为AdsPower模式的专属“包装器”
def run_automation_flow_adspower(browser_data: dict, account: dict, log_func, position_config: dict) -> str:
    """AdsPower模式的包装器：连接到浏览器，然后调用核心自动化流程。"""
    selenium_port, webdriver_path = browser_data.get('ws', {}).get('selenium'), browser_data.get('webdriver')
    if not selenium_port or not webdriver_path:
        return "Failed: Missing Selenium connection info"
 
    chrome_options = ChromeOptions()
    chrome_options.add_experimental_option("debuggerAddress", selenium_port)
    chrome_service = ChromeService(executable_path=webdriver_path)
    
    driver = None
    try:
        log_func("  - 正在连接到浏览器...")
        driver = webdriver.Chrome(service=chrome_service, options=chrome_options)
        log_func("  - [成功] Selenium 已连接。")

        # 设置窗口和位置
        try:
            log_func("正在应用窗口布局（仅移动位置）...")
            # 从配置中安全地获取 x 和 y
            pos_x = position_config.get('x', 0)
            pos_y = position_config.get('y', 0)
            driver.set_window_position(pos_x, pos_y)
            
            log_func(f"  - 窗口已移动到: x={pos_x}, y={pos_y}")
        except Exception as e:
            log_func(f"  - [警告] 移动窗口位置失败: {e}")
        
        # 调用通用的核心函数
        return execute_core_automation(driver, account, log_func)
 
    except WebDriverException as e:
        return f"Failed: Selenium Connection Error - {e}"
    except Exception as e:
        return f"Failed: An unexpected error in ads automation flow - {e}"


# CSV 账号处理部分
def read_accounts_from_csv(file_path=ACCOUNTS_FILE) -> list:
    accounts = []
    if not os.path.exists(file_path):
        print(f"[严重错误] 未找到账户文件: {file_path}")
        return []
    try:
        with open(file_path, mode='r', encoding='utf-8-sig') as csvfile:
            reader = csv.reader(csvfile)
            next(reader) 
            for i, row in enumerate(reader, 2):
                if not any(field.strip() for field in row): continue
                if len(row) >= 3:
                    accounts.append({"username": row[0].strip(), "password": row[1].strip(), "recovery_data": row[2].strip()})
                else:
                    print(f"警告：跳过文件中的第 {i} 行，因为它不包含至少3个字段。")
        print(f"成功从 {file_path} 读取 {len(accounts)} 个账户。")
        return accounts
    except Exception as e:
        print(f"[严重错误] 读取CSV文件时发生未知错误: {e}")
        return []



# 主函数
def main():
    print("=============================================")
    print("  GCP自动化脚本 (版本 6.0 - 双模式集成)")
    print("=============================================")
    print("请选择运行模式:")
    print("  1. 使用AdsPower指纹批量登录")
    print("  2. 使用本机Chrome浏览器无痕模式登录 (单账户)")
 
    choice = input("请输入选项 (1 或 2): ").strip()
 
    if choice == '1':
        print("\n--- 已选择 [AdsPower批量模式] ---\n")
        # AdsPower模式保持不变，它会从CSV读取批量账户
        run_adspower_batch_mode() 
 
    elif choice == '2':
        print("\n--- 已选择 [本机无痕模式] ---\n")
        print("请按照 '邮箱,密码,恢复数据' 的格式输入账户信息，然后按Enter键。")
        print("例如: user@example.com,YourPassword123,your_recovery_email@domain.com")
        print("或者: user@example.com,YourPassword123,your2fakey")
        
        user_input = input("请输入账户信息: ").strip()
        
        # 解析用户输入
        parts = user_input.split(',')
        if len(parts) != 3:
            print("[错误] 输入格式不正确，必须包含三个部分，用逗号分隔。程序退出。")
            return
            
        # 将解析后的信息打包成与CSV格式一致的字典
        account_info = {
            "username": parts[0].strip(),
            "password": parts[1].strip(),
            "recovery_data": parts[2].strip()
        }
 
        # 调用本地模式函数，并将账户信息传递过去
        run_local_incognito_mode(account_info)
 
    else:
        print("无效的输入，程序退出。")


def run_adspower_batch_mode():
    print(f"--- 批量登录GCP账号提取脚本 (多线程节流版) 启动 ---")
    
    # ... 初始化代码部分完全不变 ...
    if not os.path.exists(DOWNLOAD_DIR):
        os.makedirs(DOWNLOAD_DIR)
    accounts_to_process = read_accounts_from_csv()
    if not accounts_to_process: return
    proxy_usage_data = load_proxy_usage()
    try:
        available_proxies = get_all_proxies_from_manager()
    except ConnectionError as e:
        print(f"[致命错误] 无法获取代理列表，脚本终止: {e}")
        return
        
    MAX_WORKERS = 15 # 同时运行的浏览器数量上限
    API_CALL_INTERVAL = 1 # 每次调用API的最小间隔时间（秒）
    proxy_usage_lock = threading.Lock()
    results_summary = []

    layout_manager = LayoutPoolManager(WINDOW_CONFIGS)
 
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        print(f"线程池已启动，最大并发数: {MAX_WORKERS}")
        
        futures = []
        
        print("开始向线程池提交所有任务...")
        for index, account in enumerate(accounts_to_process, 1):
            print(f"  ({index}/{len(accounts_to_process)}) 正在提交任务: {account['username']}")
        
            # 提交任务到线程池
            future = executor.submit(
                process_single_account, 
                account,
                layout_manager,
                available_proxies, 
                proxy_usage_data, 
                proxy_usage_lock
            )
            futures.append(future)

            # API访问间隔
            time.sleep(API_CALL_INTERVAL)
 
        print("\n所有任务已提交，等待线程获取资源并执行...")
        for future in futures:
            results_summary.append(future.result())
 
    save_proxy_usage(proxy_usage_data)
    print("所有线程已完成工作，最终代理使用数据已保存。")
 
    print("\n\n========== 批量登录任务完成 ==========")
    print("最终报告:")
    for result in results_summary:
        print(f"  - 账户: {result['account']:<40} 状态: {result['status']}")
    print("========================================")


def run_local_incognito_mode(account_to_run: dict):
    """
    使用本地Chrome无痕模式，运行单个指定的账户。
    :param account_to_run: 包含 'username', 'password', 'recovery_data' 的字典。
    """
    
    print("\n-------------------------------------------")
    print(f"准备使用以下信息进行登录:")
    print(f"  - 账户: {account_to_run['username']}")
    print(f"  - 密码: {'*' * len(account_to_run['password'])}") # 隐藏密码
    print(f"  - 恢复数据: {account_to_run['recovery_data']}")
    print("-------------------------------------------")
 
    driver = None
    try:
        print("正在准备启动本地Chrome浏览器...")
        chrome_options = ChromeOptions()
        chrome_options.add_argument('--disable-blink-features=AutomationControlled')
        chrome_options.add_experimental_option("excludeSwitches", ["enable-automation"])
        chrome_options.add_experimental_option('useAutomationExtension', False)


        random_patch_version = random.randint(10, 105)
        dynamic_user_agent = USER_AGENT_TEMPLATE.format(CHROME_MAJOR_VERSION, CHROME_BUILD_BASE, random_patch_version)
        chrome_options.add_argument(f'user-agent={dynamic_user_agent}')
        print(f"  - 使用动态UA: {dynamic_user_agent}")
 
        chrome_options.add_argument("--incognito")
        chrome_options.add_argument("--start-maximized")
        
        service = ChromeService(ChromeDriverManager().install())
        
        driver = webdriver.Chrome(service=service, options=chrome_options)



        driver.execute_cdp_cmd(
            'Page.addScriptToEvaluateOnNewDocument',
            {
                'source': '''
                    Object.defineProperty(navigator, 'webdriver', {
                      get: () => undefined
                    });
                    delete window.cdc_adoQpoasnfa76pFCJUDiRK_Array;
                    delete window.cdc_adoQpoasnfa76pFCJUDiRK_Promise;
                    delete window.cdc_adoQpoasnfa76pFCJUDiRK_Symbol;
                '''
            }
        )
        
        print("  - [成功] 本地浏览器已启动，并已应用反检测措施。")
        def local_log(message):
            print(f"[本地模式] {message}")
        
        result = execute_core_automation(driver, account_to_run, local_log)
        
        print(f"\n--- 本地模式执行完成 ---")
        print(f"账户: {account_to_run['username']}")
        print(f"状态: {result}")
 
    except Exception as e:
        import traceback
        print(f"[致命错误] 在运行本地模式时发生异常:")
        traceback.print_exc()
    finally:
        if driver:
            print("\n自动化流程已结束。")
            close_choice = input("按 Enter 键关闭浏览器，或输入 'k' 保持浏览器打开进行调试: ").strip().lower()
            if close_choice != 'k':
                driver.quit()
            else:
                print("浏览器保持打开状态。请手动关闭。")

if __name__ == "__main__":
    main()
