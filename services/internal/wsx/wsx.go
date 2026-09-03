// Package wsx 收两个服务真正共用的那点东西。
//
// 对讲和吃饭以前是同一个二进制里的两个文件(同一个 package main),所以
// "共用"是隐式的 —— meal.go 直接调 main.go 里的 cleanField,谁也没注意到
// 那是一条跨服务依赖。拆成两个服务之后这条依赖必须显式化,否则只能复制
// 粘贴,而复制出来的两份迟早漂移。
//
// 这里只放**真正共用**的。某一个服务自己的东西不要往这里塞。
package wsx

import "strings"

// CleanField 把用户/上游送来的字符串收拾成可以安全存下来并广播出去的样子:
// 去首尾空白、丢掉控制字符,并按**字符数**(不是字节数)截断。
//
// ⚠ 按 rune 截断而不是按 byte:中文一个字三个字节,按字节切会切出半个字,
// 生成非法 UTF-8。那种字符串一旦进了 JSON,整条消息在客户端解码失败 ——
// 表现是"某个人一发言,所有人的界面就空了"。
//
// 实现与拆分之前逐字一致(原 walkie-server/main.go:659)。搬家不改行为。
func CleanField(value string, max int) string {
	value = strings.TrimSpace(value)
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	runes := []rune(value)
	if len(runes) > max {
		value = string(runes[:max])
	}
	return value
}
