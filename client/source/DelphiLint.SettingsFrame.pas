{
DelphiLint Client
Copyright (C) 2024 Integrated Application Development

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
}
unit DelphiLint.SettingsFrame;

interface

uses
    System.Classes
  , Vcl.Controls
  , Vcl.Forms
  , Vcl.StdCtrls
  , DelphiLint.IDEBaseTypes
  , DelphiLint.Events
  , Vcl.ExtCtrls
  , Data.DB
  , Vcl.Grids
  , Vcl.DBGrids
  , Vcl.DBCtrls
  , Datasnap.DBClient
  , Vcl.ComCtrls
  ;

type
  TLintSettingsFrame = class(TFrame)
    ComponentsButton: TButton;
    BrokenSetupWarningLabel: TLabel;
    ClientAutoShowToolWindowCheckBox: TCheckBox;
    ClientSaveBeforeAnalysisCheckBox: TCheckBox;
    TokensGrid: TDBGrid;
    TokensDataSource: TDataSource;
    TokensDataSet: TClientDataSet;
    DBNavigator1: TDBNavigator;
    SonarDelphiVersionComboBox: TComboBox;
    SonarDelphiVersionRadioGroup: TRadioGroup;
    Label1: TLabel;
    TopPageControl: TPageControl;
    GeneralSheet: TTabSheet;
    StandaloneSheet: TTabSheet;
    ConnectedSheet: TTabSheet;
    Label3: TLabel;
    Label4: TLabel;
    ConnectedPanel: TPanel;
    GeneralPanel: TPanel;
    StandalonePanel: TPanel;
    Label2: TLabel;
    VersionRefreshButton: TButton;
    Panel2: TPanel;
    Panel3: TPanel;
    procedure ComponentsButtonClick(Sender: TObject);
    procedure SonarDelphiVersionRadioGroupClick(Sender: TObject);
    procedure VersionRefreshButtonClick(Sender: TObject);
  private
    FOnReleasesRetrieved: TThreadSafeEventNotifier<TArray<string>>;
    FReleasesRetrieved: Boolean;
    procedure RetrieveReleases;
    procedure PopulateSonarDelphiVersionConfig(const Releases: TArray<string>);
    procedure UpdateSonarDelphiVersionEnabled;
  public
    procedure Init;
    procedure Save;
  end;

  TLintAddInOptions = class(TAddInOptionsBase)
  private
    FFrame: TLintSettingsFrame;
  public
    function GetFrameClass: TCustomFrameClass; override;
    function GetCaption: string; override;
    procedure FrameCreated(AFrame: TCustomFrame); override;
    procedure DialogClosed(Accepted: Boolean); override;
  end;

implementation

uses
    System.SysUtils
  , System.Net.HttpClient
  , System.JSON
  , System.StrUtils
  , DelphiLint.SetupForm
  , DelphiLint.Context
  , DelphiLint.Settings
  , System.Generics.Collections
  ;

{$R *.dfm}

//______________________________________________________________________________________________________________________

procedure TLintAddInOptions.FrameCreated(AFrame: TCustomFrame);
begin
  inherited;
  FFrame := TLintSettingsFrame(AFrame);
  FFrame.Init;
end;

//______________________________________________________________________________________________________________________

function TLintAddInOptions.GetCaption: string;
begin
  Result := 'DelphiLint';
end;

//______________________________________________________________________________________________________________________

function TLintAddInOptions.GetFrameClass: TCustomFrameClass;
begin
  Result := TLintSettingsFrame;
end;

//______________________________________________________________________________________________________________________

procedure TLintAddInOptions.DialogClosed(Accepted: Boolean);
begin
  inherited;
  if Accepted then begin
    FFrame.Save;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.Init;
var
  Ident: TSonarProjectIdentifier;
begin
  LintContext.Settings.Load;
  BrokenSetupWarningLabel.Visible := not TLintSetupForm.IsSetupValid;
  ClientAutoShowToolWindowCheckBox.Checked := LintContext.Settings.ClientAutoShowToolWindow;
  ClientSaveBeforeAnalysisCheckBox.Checked := LintContext.Settings.ClientSaveBeforeAnalysis;

  SonarDelphiVersionRadioGroup.Items[0] := Format(
    'Use the default version (%s)',
    [LintContext.Settings.DefaultSonarDelphiVersion]);
  if LintContext.Settings.ServerSonarDelphiVersionOverride <> '' then begin
    SonarDelphiVersionRadioGroup.ItemIndex := 1;
  end
  else begin
    SonarDelphiVersionRadioGroup.ItemIndex := 0;
  end;

  TokensDataSet.CreateDataSet;
  TokensDataSet.Open;

  TokensDataSet.DisableControls;
  try
    TokensDataSet.EmptyDataSet;

    for Ident in LintContext.Settings.SonarHostTokensMap.Keys do begin
      TokensDataSet.Append;
      TokensDataSet.FieldByName('ServerURL').AsString := Ident.Host;
      TokensDataSet.FieldByName('ProjectKey').AsString := Ident.ProjectKey;
      TokensDataSet.FieldByName('Token').AsString := LintContext.Settings.SonarHostTokensMap[Ident];
      TokensDataSet.Post;
    end;

    TokensDataSet.First;
  finally
    TokensDataSet.EnableControls;
  end;

  TokensDataSet.IndexFieldNames := 'ServerURL;ProjectKey';

  FReleasesRetrieved := False;
  UpdateSonarDelphiVersionEnabled;

  SonarDelphiVersionComboBox.Text := LintContext.Settings.ServerSonarDelphiVersionOverride;

  FOnReleasesRetrieved := TThreadSafeEventNotifier<TArray<string>>.Create;
  FOnReleasesRetrieved.AddListener(
    procedure(const Releases: TArray<string>) begin
      Log.Info('%d releases retrieved', [Length(Releases)]);
      TThread.Synchronize(
        TThread.Current,
        procedure begin
          Log.Info('%d releases retrieved (sync)', [Length(Releases)]);
          PopulateSonarDelphiVersionConfig(Releases);
        end);
    end);
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.PopulateSonarDelphiVersionConfig(const Releases: TArray<string>);
var
  SonarDelphiVersion: string;
begin
  if Length(Releases) = 0 then begin
    SonarDelphiVersionComboBox.Items.Clear;
    SonarDelphiVersionComboBox.Text := 'Could not retrieve releases';
    Exit;
  end;

  SonarDelphiVersionComboBox.Items.Clear;
  SonarDelphiVersionComboBox.Items.AddStrings(Releases);

  SonarDelphiVersion := LintContext.Settings.ServerSonarDelphiVersionOverride;
  if SonarDelphiVersion = '' then begin
    SonarDelphiVersionComboBox.ItemIndex := 0;
  end
  else begin
    SonarDelphiVersionComboBox.ItemIndex := SonarDelphiVersionComboBox.Items.IndexOf(SonarDelphiVersion);
  end;

  FReleasesRetrieved := True;
  UpdateSonarDelphiVersionEnabled;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.RetrieveReleases;
const
  CApiUrl = 'https://api.github.com/repos/integrated-application-development/sonar-delphi/releases';
var
  Http: THTTPClient;
  Response: IHTTPResponse;
  Json: TJSONArray;
  Index: Integer;
  ReleaseVersion: string;
  Releases: TArray<string>;
begin
  Http := THTTPClient.Create;
  try
    try
      Response := Http.Get(CApiUrl);
    except
      on E: ENetHTTPClientException do begin
        Log.Warn('Could not retrieve SonarDelphi releases from %s: %s', [CApiUrl, E.Message]);
        FOnReleasesRetrieved.Notify([]);
        Exit;
      end;
    end;

    if Response.StatusCode = 200 then begin
      Json := TJSONObject.ParseJSONValue(Response.ContentAsString) as TJSONArray;
      try
        SetLength(Releases, Json.Count);

        for Index := 0 to Json.Count - 1 do begin
          ReleaseVersion := Json[Index].GetValue<string>('tag_name');

          if StartsStr('v', ReleaseVersion) and (Length(ReleaseVersion) > 1) then begin
            ReleaseVersion := Copy(ReleaseVersion, 2);
          end;

          Releases[Index] := ReleaseVersion;
        end;
      finally
        FreeAndNil(Json);
      end;

      FOnReleasesRetrieved.Notify(Releases);
    end;
  finally
    FreeAndNil(Http);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.Save;
var
  Tokens: TDictionary<TSonarProjectIdentifier, string>;
begin
  Tokens := LintContext.Settings.SonarHostTokensMap;

  TokensDataSet.DisableControls;
  try
    Tokens.Clear;

    TokensDataSet.First;
    while not TokensDataSet.Eof do begin
      if (TokensDataSet.FieldByName('ServerURL').AsString <> '') then begin
        Tokens.AddOrSetValue(
          TSonarProjectIdentifier.Create(
            TokensDataSet.FieldByName('ServerURL').AsString,
            TokensDataSet.FieldByName('ProjectKey').AsString),
          TokensDataSet.FieldByName('Token').AsString);
      end;

      TokensDataSet.Next;
    end;
  finally
    TokensDataSet.EnableControls;
  end;

  LintContext.Settings.ClientAutoShowToolWindow := ClientAutoShowToolWindowCheckBox.Checked;
  LintContext.Settings.ClientSaveBeforeAnalysis := ClientSaveBeforeAnalysisCheckBox.Checked;

  if FReleasesRetrieved or (SonarDelphiVersionRadioGroup.ItemIndex = 0) then begin
    LintContext.Settings.ServerSonarDelphiVersionOverride := IfThen(
      (SonarDelphiVersionRadioGroup.ItemIndex = 1) and (SonarDelphiVersionComboBox.ItemIndex <> -1),
      SonarDelphiVersionComboBox.Items[SonarDelphiVersionComboBox.ItemIndex],
      ''
    );
  end;
  LintContext.Settings.Save;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.SonarDelphiVersionRadioGroupClick(Sender: TObject);
begin
  UpdateSonarDelphiVersionEnabled;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.UpdateSonarDelphiVersionEnabled;
begin
  SonarDelphiVersionComboBox.Enabled := (SonarDelphiVersionRadioGroup.ItemIndex = 1) and FReleasesRetrieved;
  VersionRefreshButton.Enabled := (SonarDelphiVersionRadioGroup.ItemIndex = 1) and not FReleasesRetrieved;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.VersionRefreshButtonClick(Sender: TObject);
var
  Thread: TThread;
begin
  if FReleasesRetrieved then begin
    Exit;
  end;

  Thread := TThread.CreateAnonymousThread(
    procedure begin
      RetrieveReleases;
    end);
  Thread.FreeOnTerminate := True;
  Thread.Start;
end;

//______________________________________________________________________________________________________________________

procedure TLintSettingsFrame.ComponentsButtonClick(Sender: TObject);
var
  SetupForm: TLintSetupForm;
begin
  SetupForm := TLintSetupForm.Create(nil);
  try
    SetupForm.RefreshTheme;
    SetupForm.ShowModal;
  finally
    FreeAndNil(SetupForm);
  end;

  BrokenSetupWarningLabel.Visible := not TLintSetupForm.IsSetupValid;
end;

//______________________________________________________________________________________________________________________

end.
