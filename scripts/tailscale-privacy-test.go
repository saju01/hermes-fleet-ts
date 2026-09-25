package main

import (
    "bytes"
    "log"
    "testing"
)

func TestDisabledLogsDoNotEmitUserAuthMessages(t *testing.T) {
    handle := TsnetNewServer()
    defer TsnetClose(handle)
    if result := TsnetSetLogFD(handle, -1); result != 0 { t.Fatal("set log fd failed") }
    var output bytes.Buffer
    previous := log.Writer()
    log.SetOutput(&output)
    defer log.SetOutput(previous)
    userLog := getServer(handle).s.UserLogf
    if userLog == nil { userLog = log.Printf }
    userLog("SYNTHETIC-ENROLLMENT-NOT-A-REAL-URL")
    if output.Len() != 0 { t.Fatal("disabled SDK logging still emits user enrollment messages") }
}
