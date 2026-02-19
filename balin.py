import pyautogui
import time

count = 0
while True:
    pyautogui.click()
    count += 1     
    print(f"Test {count}")
    time.sleep(5)