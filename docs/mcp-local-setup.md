# Local MCP setup

Agent Plugin 1.0 uses the root `plugin.json` and `mcp.json`.
Install OneScript 2.1.0 and put `oscript` on the client process PATH.

From the repository root, after a fresh dependency installation:

```sh
opm install --local
git apply --ignore-space-change patches/autumn-mcp-discovery.patch
codex plugin marketplace add .
codex plugin add vanessa-runner@vanessa-runner-local
```

The patch targets autumn-mcp 1.1.2: `resources/templates/list` returns an empty
list; unknown requests receive JSON-RPC error -32601. Notifications remain
unanswered. Without this fix, Codex discovery waits for a response indefinitely.
Apply the patch only once per fresh dependency installation.

Codex copies the package including `oscript_modules` into its cache. Refresh it
with `codex plugin add` after source or dependency changes. The manifest does
not automatically install OneScript or OPM dependencies.

## Управляемое предприятие и Vanessa (Agent Plugin: supervisor 0.3.2)

`run_enterprise` принимает абсолютный `ibpath` существующей файловой базы и установленную `v8version`. Ответ `starting` содержит `runId`; PID и окно проверяются отдельным `enterprise_status`. `infobase_init` очищает существующую базу — не используйте его для повторного прогона.

В Windows без ibsrv команда `test_vanessa` использует того же владельца процессов. Фоновый `taskId` возвращается сразу; `task_result` публикует `Vanessa runId: <UUID>`. Статус сценария доступен до выхода менеджера. `enterprise_stop` запрашивает штатное закрытие клиентов, затем менеджера. `timeoutSeconds` 0–30 ограничивает только ожидание ответа. Общего предела длительности задачи и принудительного завершения нет.

Ответы наблюдателя версии 0.3.2 содержат `driverVersion`, `scenarioStatus`, `cleanupStatus`, `result`, `processes`. Успех Vanessa требует результата `passed` и выхода менеджера и клиентов с кодом 0 и отсутствия живых потомков в Job Object. Успешный сценарий при живом клиенте даёт `cleanup_pending`. `processes` также показывает наблюдаемые вспомогательные процессы с ролью `helper`; им не отправляется запрос закрытия окна, но их выход учитывается при завершении группы. Отсутствующий/невалидный статус не считается успехом.

Состояние: `%LOCALAPPDATA%/VanessaRunner/runs/<runId>/state.json`. Скрытый PowerShell-наблюдатель входит в отдельный Windows Job Object до запуска 1С. ОС включает в него всех потомков, даже если промежуточный launcher уже завершился. Уведомления Job Object будят наблюдатель; состав группы проверяется через QueryInformationJobObject. `processTracking: named_windows_job` и `activeProcessCount` показывают механизм и число живых потомков (без самого наблюдателя). Пока это число не равно нулю, `cleanupStatus: exited` и `result: passed` невозможны. Ожидание уведомления ограничено одной секундой для обслуживания файлов статуса и команд закрытия; это интервал наблюдения, не дедлайн. Job Object не включает принудительное завершение при закрытии дескриптора. Удерживаемые дескрипторы защищают от повторного использования PID. Наблюдатель не принимает ранее открытые и удалённые клиенты; управляет только собственным деревом 1С. Потеря наблюдателя возвращает `supervision_lost`, а не ложный успех.

Наблюдатель запускается через локальный `Win32_Process.Create` вне группы процесса MCP. При отключении MCP его kill-on-close группа не владеет наблюдателем и 1С. Отдельный независимый держатель сохраняет дескриптор именованной группы `Local\VanessaRunner.Run.<runId>` до выхода её процессов. Завершение обоих владельцев не считается очисткой.

`enterprise_recover(runId)` — явное восстановление наблюдения прежнего запуска, без нового `test_vanessa` или `run_enterprise`. `recoveryStatus=observer_restarted` означает повторное открытие той же группы; `cleanup_confirmed` содержит квитанцию ядра или факт новой загрузки Windows. Потерянные коды выхода не восстанавливаются из догадок: после подтверждения очистки потерянный прогон возвращает `result=failed`, `scenarioStatus=unknown`. Отсутствие имени группы само по себе не доказывает выход процессов. Для потерянной группы владелец проверяет сохранённые идентификаторы процессов и захватывает существующий файл базы без совместного доступа. Если собственные процессы вышли и файл свободен, `cleanupStatus=released`, `activeProcessCount=null`, `recoveryStatus=resources_released` закрывают только неуспешный прогон. `recoveryProof=infobase_exclusive` подтверждает освобождение ресурса, а не выход неизвестных потомков и не успех сценария. Занятый файл или живой собственный процесс дают отказ; перезагрузка Windows не требуется.

Хранилище имеет один физический адрес. В MSIX-хосте Windows может перенаправлять `%LOCALAPPDATA%`; после создания каталога его физический адрес получается через `GetFinalPathNameByHandle` и передаётся независимым помощникам в `StoreRoot`. Копий состояния и поиска запасных каталогов нет. `job-lease.json` хранит квитанцию группы; `owner-*.log` — ошибки старта помощников. Каталог конкретного запуска доступен только текущему пользователю.

После переподключения MCP доступен сохранённый runId; taskId фонового worker остаётся в прежнем MCP-процессе. Реестр старой версии 0.2.x не переносится. Командная строка запуска хранится кратковременно в файле с доступом только текущего пользователя и удаляется наблюдателем; файл состояния не содержит пароля.

Полная официальная поставка Vanessa Automation Single и режим снимков 1 подходят для автономных проверок. Наличие EPF не проверяет комплектность библиотек/компонент. Владелец подтверждает только открытие точного EPF из /Execute своего запуска и штатный вопрос завершения после своего запроса закрытия. Управление адресовано проверенному окну, без глобальной клавиатуры и смены foreground; отключение RDP само по себе не запрещает наблюдение, TestClient или запись. Прочие предупреждения и изменение защиты 1С не разрешаются автоматически. Исправление режима снимков 2 не входит в этот контракт.

### Ограниченный каталог в Codex

При большом количестве подключённых MCP клиент может обрезать доступный агенту
каталог. В конфигурации **конкретного workspace** можно оставить нужные команды:

```toml
[mcp_servers.vanessa-runner]
command = "oscript"
args = ["C:/path/to/vanessa-runner/src/mcp.os"]
cwd = "C:/path/to/vanessa-runner"
enabled_tools = [
  "infobase_init", "infobase_update", "cf_compile", "cf_convert", "cf_load",
  "cf_unload", "test_vanessa", "run_enterprise", "enterprise_status", "enterprise_stop",
  "task_status", "task_result", "task_cancel", "cache_show", "cache_clear"
]
```

Замените путь на фактический установленный пакет. Переподключайте сервер до
начала сценария, затем проверяйте инструменты реальными вызовами из чата.


Integration check (Windows, Node.js, installed 1C):

```text
node tests/e2e/mcp-enterprise.mjs ROOT OSCRIPT OUTPUT_DIRECTORY PLATFORM_VERSION
```

The check creates a new database under OUTPUT_DIRECTORY, opens and gracefully
closes its own run through MCP, and verifies rejection of foreign runIds and
invalid parameters. It preserves JSON evidence and the test database. This
separate protocol check does not prove tool availability inside the IDE chat.

`enterprise_status` judges an interactive session by what happened on screen, not by the
exit code alone: a client that quits before its main window ever appears (the platform
reported an error and closed) is `result: failed` with `failureReason: exited_before_window`,
and `lastPlatformError` carries the last error record of the infobase event log
(`1Cv8Log`). `bad_exit` names a non-zero or unknown exit code, `scenario_<status>` a
Vanessa run whose scenario did not pass. `windowSeen` stays `true` once a window was shown.

Focused lifecycle regression (does not start 1C or a separate MCP client). The same script runs inside the unit gate (`oscript tasks/test_unit.os`, set `ТестСупервизорПредприятия`) on Windows:

```powershell
powershell -NoProfile -File tests/unit/enterprise-lifecycle.ps1 -Helper "$PWD/tools/enterprise-window.ps1"
```

For active plugin development, point the workspace MCP configuration at a stable source directory (for example a local checkout of `vanessa-runner`) and the real OneScript executable. This avoids pinning an obsolete version in the plugin cache. A running MCP connection still needs reconnection to load changed source. A plugin installation alone does not reload tools in an already running chat.


## macOS: подготовка и проверка

Сценарий: [диагностика и запуск сценариев на macOS](use-cases/macos-reproduction.md).
Требуются лицензированная платформа 1С, Python 3, Swift (Command Line Tools)
и официальный OneScript 2.2.1 для архитектуры Mac. Пакет есть в каталоге
https://oscript.io/downloads; GitHub Releases может отставать. OVM из GitHub
в текущем mise.toml поставляется только для Windows: на Mac используйте
нативный архив OneScript. Распаковывайте архив с сохранением Unicode-имён.
Если официальный ARM apphost не подписан, для локального запуска выполните
`codesign --force --sign - /absolute/path/to/bin/oscript`.

Проверьте `oscript -version`. OPM вызывается тем же движком:
`oscript /absolute/path/to/lib/opm/src/cmd/opm.os install --local --dev`.
Для штатных тестов путь `oscript_modules/bin` и каталог OneScript должны
быть в PATH. В `oscript_modules/oneunit/src/cli/oscript.cfg` должно быть
`lib.additional=../../..`.

`test_vanessa` без ibsrv использует наблюдатель `tools/enterprise-macos.py`.
Состояние находится в `~/Library/Application Support/VanessaRunner/runs`.
Успех требует свежего файла статуса Vanessa со значением 0, нулевого кода
выхода менеджера и завершения всех процессов его собственной группы.
`enterprise_status` доступен после переподключения MCP. `enterprise_stop`
запрашивает завершение собственных приложений через NSRunningApplication;
`enterprise_cancel` отдельно отправляет SIGTERM собственным процессам и
никогда не выдаёт отмену за успешный сценарий. Потерянный наблюдатель не
восстанавливает достоверность старого запуска и не запускает 1С повторно.
Подготовленный Windows-запуск, автоматическое подтверждение лицензии и
`enterprise_authorize`/`enterprise_execute` на Mac не поддерживаются.
Наличие процесса не доказывает появление окна.

Проверки:

```sh
python3 -m unittest discover -s tests/native -p test_macos_supervisor.py
oscript tests/native/macos-bridge.os
oscript tasks/test_unit.os
```

### Явное доверие локальным тестовым базам на macOS

Если журнал регистрации подтверждает остановку на разрешении открыть Vanessa,
настройте только согласованные локальные тестовые базы. Это разрешает в них внешние обработки,
компоненты и запуск программ, поэтому не является универсальным ответом на любые
предупреждения. Скрипт по умолчанию только показывает план:

```sh
python3 tools/macos-trusted-infobases.py --infobase /absolute/path/to/test-base
```

После явного согласия владельца на указанную базу повторите с
`--apply --acknowledge-trust-change`. Для нескольких баз повторяйте `--infobase`.
Запись в пользовательском `conf.cfg` ограничена точными каноническими путями
существующих файловых баз. Настройки других баз сохраняются. Для отзыва тех же
разрешений используйте `--revoke --apply --acknowledge-trust-change` с теми же путями.
Перезапустите только собственный завершённый прогон и проверьте реальный результат.

Справочник платформы: [DisableUnsafeActionProtection](https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Appendix_3._Description_and_location_of_internal_files/3.17._conf.cfg/3.17.6._DisableUnsafeActionProtection/?language=en).


### Feature и отчёты Vanessa Automation

`test_vanessa --feature-path` теперь записывает `КаталогФич` в копию настроек, а не только переменную среды Vanessa-ADD. Опция `--libraries` передаёт каталоги определений шагов. Относительные пути разрешаются от `--workspace`; отсутствующие feature и библиотеки отклоняются до старта платформы. Исходный JSON не переписывается.

Управляемый прогон запускает сценарии и завершает систему после отчёта как при синхронном ожидании, так и при `--no-wait`; режим `--prepare` остаётся отдельным. `--report-format allure` включает также флаг Vanessa Automation. По-прежнему требуется совместимая установленная библиотека шагов: произвольный текст Gherkin не становится исполнимым от наличия запускающего инструмента.


### Преднастроенное окружение запуска

Для преднастроенного окружения MCP задаются переменные: `VRUNNER_WORKSPACE`, `VRUNNER_IBCONNECTION`,
`VRUNNER_PATHVANESSA`, `VRUNNER_V8VERSION` и `VRUNNER_VANESSA_BASE_SETTINGS`.
Последний параметр указывает JSON с библиотеками шагов и общими настройками
Vanessa Automation. Индивидуальные настройки прогона перекрывают базовые;
исходные файлы остаются неизменными. Агент передаёт `feature-path` относительно
workspace. В отсутствие явных настроек отчётов Runner создаёт JUnit и Allure
в отдельном `runtime/runs/<runId>`; готовый отчёт необходимо прочитать.

На macOS файловая база проверяется до запуска: путь `/F` должен содержать
`1Cv8.1CD`. Ошибка пути возвращается инструментом, не оставляя клиента
в ожидании интерактивного окна. Проверка не создаёт базу и не меняет её защиту.

`scenario_failed` сам по себе не подтверждает дефект учёта: неизвестный шаг,
ошибка синтаксиса и сбой подготовки требуют исправления сценария. При анализе
результата проверяются шаги, ожидаемые и фактические значения в исходном
отчёте именно этого runId. Отсутствующий отчёт не считается доказательством.

В macOS-квитанции `enterprise_status` поле `reportEvidence` содержит пути исходного JUnit и результаты его сценариев. Статусы `missing`, `empty`, `unreadable` не подтверждают проверку. Текст ошибок передаётся также в лог фоновой задачи: агент получает причину через `task_result` без перепечатывания пути к файлу.
