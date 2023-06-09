unit DelphiLint.Context;

interface

uses
    DelphiLint.Server
  , System.Classes
  , DelphiLint.Data
  , System.Generics.Collections
  , DelphiLint.Logger
  , DelphiLint.Events
  ;

type
  TLiveIssue = class(TObject)
  private
    FRuleKey: string;
    FMessage: string;
    FFilePath: string;
    FStartLine: Integer;
    FEndLine: Integer;
    FStartLineOffset: Integer;
    FEndLineOffset: Integer;
    FLinesMoved: Integer;

    function GetStartLine: Integer;
    function GetEndLine: Integer;

  public
    property RuleKey: string read FRuleKey;
    property Message: string read FMessage;
    property FilePath: string read FFilePath write FFilePath;
    property OriginalStartLine: Integer read FStartLine;
    property OriginalEndLine: Integer read FEndLine;
    property StartLine: Integer read GetStartLine;
    property EndLine: Integer read GetEndLine;
    property StartLineOffset: Integer read FStartLineOffset;
    property EndLineOffset: Integer read FEndLineOffset;
    property LinesMoved: Integer read FLinesMoved write FLinesMoved;

    constructor CreateFromData(Issue: TLintIssue);
    procedure NewLineMoveSession;
  end;

  TFileAnalysisHistory = record
    AnalysisTime: TDateTime;
    Success: Boolean;
    IssuesFound: Integer;
    FileHash: string;
  end;

  TCurrentAnalysis = class(TObject)
  private
    FPaths: TArray<string>;
  public
    constructor Create(Paths: TArray<string>);
    property Paths: TArray<string> read FPaths;
  end;

  TFileAnalysisStatus = (
    fasNeverAnalyzed,
    fasOutdatedAnalysis,
    fasUpToDateAnalysis
  );

  TLintContext = class(TObject)
  private
    FServer: TLintServer;
    FActiveIssues: TObjectDictionary<string, TObjectList<TLiveIssue>>;
    FFileAnalyses: TDictionary<string, TFileAnalysisHistory>;
    FOutputLog: TLintLogger;
    FCurrentAnalysis: TCurrentAnalysis;
    FOnAnalysisStarted: TEventNotifier<TArray<string>>;
    FOnAnalysisComplete: TEventNotifier<TArray<string>>;
    FOnAnalysisFailed: TEventNotifier<TArray<string>>;

    function ToUnixPath(Path: string; Lower: Boolean = False): string;
    procedure OnAnalyzeResult(Issues: TArray<TLintIssue>);
    procedure OnAnalyzeError(Message: string);
    procedure SaveIssues(Issues: TArray<TLintIssue>);
    procedure DisplayIssues;
    function GetOrInitServer: TLintServer;
    procedure RecordAnalysis(Path: string; Success: Boolean; IssuesFound: Integer);
    function GetInAnalysis: Boolean;

  public
    constructor Create;
    destructor Destroy; override;

    function GetIssues(FileName: string; Line: Integer = -1): TArray<TLiveIssue>; overload;

    procedure UpdateIssueLine(FilePath: string; OriginalLine: Integer; NewLine: Integer);

    procedure AnalyzeFiles(
      const Files: TArray<string>;
      const BaseDir: string;
      const SonarHostUrl: string = '';
      const ProjectKey: string = '');
    procedure AnalyzeActiveFile;

    function GetAnalysisStatus(Path: string): TFileAnalysisStatus;
    function TryGetAnalysisHistory(Path: string; out History: TFileAnalysisHistory): Boolean;

    property OnAnalysisStarted: TEventNotifier<TArray<string>> read FOnAnalysisStarted;
    property OnAnalysisComplete: TEventNotifier<TArray<string>> read FOnAnalysisComplete;
    property OnAnalysisFailed: TEventNotifier<TArray<string>> read FOnAnalysisFailed;

    property CurrentAnalysis: TCurrentAnalysis read FCurrentAnalysis;
    property InAnalysis: Boolean read GetInAnalysis;
  end;

function LintContext: TLintContext;
function LintContextValid: Boolean;

implementation

uses
    ToolsAPI
  , DelphiLint.ProjectOptions
  , DelphiLint.IDEUtils
  , System.IOUtils
  , System.SysUtils
  , System.StrUtils
  , System.Generics.Defaults
  , DelphiLint.Settings
  , Vcl.Dialogs
  , System.Hash
  , System.DateUtils
  ;

var
  GLintContext: TLintContext;
  GContextInvalid: Boolean;

//______________________________________________________________________________________________________________________

function LintContext: TLintContext;
begin
  if LintContextValid and not Assigned(GLintContext) then begin
    GLintContext := TLintContext.Create;
  end;
  Result := GLintContext;
end;

//______________________________________________________________________________________________________________________

function LintContextValid: Boolean;
begin
  Result := not GContextInvalid;
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.AnalyzeActiveFile;
var
  AllFiles: TArray<string>;
  ProjectFile: string;
  MainFile: string;
  PasFiles: TArray<string>;
  SourceEditor: IOTASourceEditor;
  ProjectOptions: TLintProjectOptions;
  ProjectDir: string;
begin
  SourceEditor := DelphiLint.IDEUtils.GetCurrentSourceEditor;
  if not Assigned(SourceEditor) then begin
    Exit;
  end;

  DelphiLint.IDEUtils.ExtractFiles(AllFiles, ProjectFile, MainFile, PasFiles);

  ProjectOptions := TLintProjectOptions.Create(ProjectFile);
  ProjectDir := ProjectOptions.ProjectBaseDir;
  if ProjectDir = '' then begin
    ProjectDir := TPath.GetDirectoryName(ProjectFile);
  end;

  AnalyzeFiles(
    [SourceEditor.FileName],
    ProjectDir,
    ProjectOptions.SonarHostUrl,
    ProjectOptions.ProjectKey);
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.AnalyzeFiles(
  const Files: TArray<string>;
  const BaseDir: string;
  const SonarHostUrl: string = '';
  const ProjectKey: string = '');
var
  Server: TLintServer;
begin
  if Assigned(FCurrentAnalysis) then begin
    Log.Info('Already in analysis.');
    Exit;
  end;

  FOutputLog.Clear;
  FCurrentAnalysis := TCurrentAnalysis.Create(Files);
  FOnAnalysisStarted.Notify(Files);

  Server := GetOrInitServer;
  if Assigned(Server) then begin
    Log.Info('Server connected for analysis.');
    Server.Analyze(
      BaseDir,
      Files,
      OnAnalyzeResult,
      OnAnalyzeError,
      SonarHostUrl,
      ProjectKey);
  end
  else begin
    Log.Info('Server connection could not be established.');
    FOutputLog.Info('Analysis failed - server connection could not be established.');
    FOnAnalysisFailed.Notify(Files);
  end;
end;

//______________________________________________________________________________________________________________________

constructor TLintContext.Create;
begin
  inherited;
  FActiveIssues := TObjectDictionary<string, TObjectList<TLiveIssue>>.Create;
  FOutputLog := TLintLogger.Create('Issues');
  FCurrentAnalysis := nil;
  FFileAnalyses := TDictionary<string, TFileAnalysisHistory>.Create;
  FOnAnalysisStarted := TEventNotifier<TArray<string>>.Create;
  FOnAnalysisComplete := TEventNotifier<TArray<string>>.Create;
  FOnAnalysisFailed := TEventNotifier<TArray<string>>.Create;

  Log.Clear;
  Log.Info('DelphiLint started.');
end;

//______________________________________________________________________________________________________________________

destructor TLintContext.Destroy;
begin
  FreeAndNil(FServer);
  FreeAndNil(FActiveIssues);
  FreeAndNil(FOutputLog);
  FreeAndNil(FFileAnalyses);
  FreeAndNil(FOnAnalysisStarted);
  FreeAndNil(FOnAnalysisComplete);
  FreeAndNil(FOnAnalysisFailed);
  FreeAndNil(FCurrentAnalysis);

  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.DisplayIssues;
var
  FileIssues: TArray<TLiveIssue>;
  Issue: TLiveIssue;
  FileName: string;
  Stale: Boolean;
begin
  FOutputLog.Clear;

  for FileName in FActiveIssues.Keys do begin
    FileIssues := GetIssues(FileName);
    FOutputLog.Title(Format('[DelphiLint] %s (%d issues)', [FileIssues[0].FilePath, Length(FileIssues)]));
    Stale := GetAnalysisStatus(FileName) = fasOutdatedAnalysis;

    for Issue in FileIssues do begin
      FOutputLog.Info(
        Format('%s%s', [Issue.Message, IfThen(Stale, ' (outdated)', '')]),
        Issue.FilePath,
        Issue.StartLine,
        Issue.StartLineOffset);
    end;
  end;

  RefreshEditorWindows;
end;

//______________________________________________________________________________________________________________________

function OrderByStartLine(const Left, Right: TLiveIssue): Integer;
begin
  Result := TComparer<Integer>.Default.Compare(Left.OriginalStartLine, Right.OriginalStartLine);
end;

//______________________________________________________________________________________________________________________

function TLintContext.GetInAnalysis: Boolean;
begin
  Result := Assigned(FCurrentAnalysis);
end;

//______________________________________________________________________________________________________________________

function TLintContext.GetIssues(FileName: string; Line: Integer = -1): TArray<TLiveIssue>;
var
  SanitizedName: string;
  Issue: TLiveIssue;
  ResultList: TList<TLiveIssue>;
begin
  SanitizedName := ToUnixPath(FileName, True);
  if FActiveIssues.ContainsKey(SanitizedName) then begin
    if Line = -1 then begin
      Result := FActiveIssues[SanitizedName].ToArray;
      TArray.Sort<TLiveIssue>(Result, TComparer<TLiveIssue>.Construct(OrderByStartLine));
    end
    else begin
      ResultList := TList<TLiveIssue>.Create;
      try
        for Issue in FActiveIssues[SanitizedName] do begin
          if (Issue.StartLine >= Line) and (Issue.EndLine <= Line) then begin
            ResultList.Add(Issue);
          end;
        end;

        ResultList.Sort(TComparer<TLiveIssue>.Construct(OrderByStartLine));
        Result := ResultList.ToArray;
      finally
        FreeAndNil(ResultList);
      end;
    end;
  end;
end;

//______________________________________________________________________________________________________________________

function TLintContext.GetOrInitServer: TLintServer;
begin
  if not Assigned(FServer) then begin
    try
      FServer := TLintServer.Create(LintSettings.ServerPort);
    except
      ShowMessage('Server connection could not be established.');
      FServer := nil;
    end;
  end;
  Result := FServer;
end;

//______________________________________________________________________________________________________________________

function TLintContext.GetAnalysisStatus(Path: string): TFileAnalysisStatus;
var
  SanitizedPath: string;
  History: TFileAnalysisHistory;
begin
  SanitizedPath := ToUnixPath(Path, True);

  if FFileAnalyses.ContainsKey(SanitizedPath) then begin
    History := FFileAnalyses[SanitizedPath];
    if THashMD5.GetHashStringFromFile(Path) = History.FileHash then begin
      Result := TFileAnalysisStatus.fasUpToDateAnalysis;
    end
    else begin
      Result := TFileAnalysisStatus.fasOutdatedAnalysis;
    end;
  end
  else begin
    Result := TFileAnalysisStatus.fasNeverAnalyzed;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.OnAnalyzeError(Message: string);
var
  Path: string;
begin
  FOutputLog.Info('Error during analysis: ' + Message);

  for Path in FCurrentAnalysis.Paths do begin
    RecordAnalysis(Path, False, 0);
  end;

  FOnAnalysisFailed.Notify(FCurrentAnalysis.Paths);

  FreeAndNil(FCurrentAnalysis);

  ShowMessage('There was an error during analysis.' + #13#10 + Message);
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.OnAnalyzeResult(Issues: TArray<TLintIssue>);
begin
  SaveIssues(Issues);

  FreeAndNil(FCurrentAnalysis);
  FOnAnalysisComplete.Notify(FCurrentAnalysis.Paths);

  DisplayIssues;
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.RecordAnalysis(Path: string; Success: Boolean; IssuesFound: Integer);
var
  SanitizedPath: string;
  History: TFileAnalysisHistory;
begin
  History.AnalysisTime := Now;
  History.Success := Success;
  History.IssuesFound := IssuesFound;
  History.FileHash := THashMD5.GetHashStringFromFile(Path);

  SanitizedPath := ToUnixPath(Path, True);
  FFileAnalyses.AddOrSetValue(SanitizedPath, History);

  Log.Info(Format(
    'Analysis recorded for %s at %s, (%s, %d issues found)',
    [
      Path,
      FormatDateTime('hh:nn:ss', History.AnalysisTime),
      IfThen(Success, 'successful', 'failure'),
      IssuesFound
    ]));
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.SaveIssues(Issues: TArray<TLintIssue>);
var
  Issue: TLintIssue;
  LiveIssue: TLiveIssue;
  SanitizedPath: string;
  NewIssues: TDictionary<string, TObjectList<TLiveIssue>>;
  Path: string;
  NewIssuesForFile: TObjectList<TLiveIssue>;
  IssueCount: Integer;
begin
  Log.Info(Format('Processing %d issues.', [Length(Issues)]));

  NewIssues := TDictionary<string, TObjectList<TLiveIssue>>.Create;
  try
    // Split issues by file and convert to live issues
    for Issue in Issues do begin
      LiveIssue := TLiveIssue.CreateFromData(Issue);

      SanitizedPath := ToUnixPath(Issue.FilePath, True);
      if not NewIssues.ContainsKey(SanitizedPath) then begin
        NewIssues.Add(SanitizedPath, TObjectList<TLiveIssue>.Create);
      end;
      NewIssues[SanitizedPath].Add(LiveIssue);
    end;

    // Process issues per file
    for Path in FCurrentAnalysis.Paths do begin
      SanitizedPath := ToUnixPath(Path, True);

      // Remove current active issues
      if FActiveIssues.ContainsKey(SanitizedPath) then begin
        FActiveIssues.Remove(SanitizedPath);
      end;

      // Add new active issues (if there are any)
      IssueCount := 0;
      if NewIssues.TryGetValue(SanitizedPath, NewIssuesForFile) then begin
        FActiveIssues.Add(SanitizedPath, NewIssuesForFile);
        IssueCount := FActiveIssues[SanitizedPath].Count;
      end;

      // Record analysis
      RecordAnalysis(Path, True, IssueCount);
      Log.Info(Format('%d issues recorded for %s', [IssueCount, Path]));
    end;
  finally
    FreeAndNil(NewIssues);
  end;
end;

//______________________________________________________________________________________________________________________

function TLintContext.ToUnixPath(Path: string; Lower: Boolean = False): string;
begin
  if Lower then begin
    Path := LowerCase(Path);
  end;

  Result := StringReplace(Path, '\', '/', [rfReplaceAll]);
end;

//______________________________________________________________________________________________________________________

function TLintContext.TryGetAnalysisHistory(Path: string; out History: TFileAnalysisHistory): Boolean;
begin
  Result := FFileAnalyses.TryGetValue(ToUnixPath(Path, True), History);
end;

//______________________________________________________________________________________________________________________

procedure TLintContext.UpdateIssueLine(FilePath: string; OriginalLine, NewLine: Integer);
var
  SanitizedPath: string;
  Issue: TLiveIssue;
  Delta: Integer;
  Index: Integer;
begin
  SanitizedPath := ToUnixPath(FilePath, True);

  Delta := NewLine - OriginalLine;

  Log.Info(Format('Updating line from %d to %d (delta %d)', [OriginalLine, NewLine, Delta]));

  if FActiveIssues.ContainsKey(SanitizedPath) then begin
    for Index := 0 to FActiveIssues[SanitizedPath].Count - 1 do begin
      Issue := FActiveIssues[SanitizedPath][Index];

      if Issue.OriginalStartLine = OriginalLine then begin
        Issue.LinesMoved := Delta;
      end;
    end;
  end;
end;

//______________________________________________________________________________________________________________________

constructor TLiveIssue.CreateFromData(Issue: TLintIssue);
begin
  FRuleKey := Issue.RuleKey;
  FMessage := Issue.Message;
  FFilePath := Issue.FilePath;
  FStartLine := Issue.Range.StartLine;
  FEndLine := Issue.Range.EndLine;
  FStartLineOffset := Issue.Range.StartLineOffset;
  FEndLineOFfset := Issue.Range.EndLineOffset;
  FLinesMoved := 0;
end;

function TLiveIssue.GetStartLine: Integer;
begin
  Result := FStartLine + LinesMoved;
end;

function TLiveIssue.GetEndLine: Integer;
begin
  Result := FEndLine + LinesMoved;
end;

procedure TLiveIssue.NewLineMoveSession;
begin
  FStartLine := StartLine;
  FEndLine := EndLine;
  FLinesMoved := 0;
end;

{ TCurrentAnalysis }

constructor TCurrentAnalysis.Create(Paths: TArray<string>);
begin
  FPaths := Paths;
end;

initialization
  GContextInvalid := False;

finalization
  FreeAndNil(GLintContext);
  GContextInvalid := True;

end.
