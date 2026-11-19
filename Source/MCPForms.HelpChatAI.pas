unit MCPForms.HelpChatAI;

(* delphi-mcp-forms - the form tools as a skill of HelpChatAI.

  HelpChatAI (github.com/EtheaDev/Delphi-HelpChatAI, Apache 2.0) is an in-app
  assistant for VCL and FMX applications: what it can do in the application
  are "actions", grouped in "skills" an application turns on by name. This
  unit registers the skill "mcpforms": with it the assistant reaches every
  form tool declared with delphi-mcp-forms, without one action per form.

    uses MCPForms.HelpChatAI;
    HelpChat.Settings.Skills := 'forms, commands, mcpforms';

  The actions are always the same three, whichever forms are open (the
  assistant caches the list of its tools):
    mcp_list_forms     the form tools of the application: name, title,
                       whether the form is open, description;
    mcp_describe_form  the parameters of one, from its input schema;
    mcp_fill_form      fills one (the user confirms the values first), brings
                       it forward and highlights it, and returns at once: it
                       never submits, the user reviews the values and saves.

  The action names do not collide with those of the "forms" skill of
  HelpChatAI (describe_form, fill_form...), which works on the window in front
  of the user; this one works on the form tools, open in front or not.

  This is the only unit of the library that uses HelpChatAI: add it to an
  application that has HelpChatAI on its search path. It is framework-neutral
  (MCPForms.VCL or MCPForms.FMX provide the form tools).

  MIT License - see LICENSE. *)

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  HelpChatAI.Messages, HelpChatAI.Actions, HelpChatAI.Skills,
  MCPForms.Core, MCPForms.FormTool;

const
  /// The name to put in Settings.Skills.
  MCPFORMS_SKILL_NAME = 'mcpforms';
  MCPFORMS_ACTION_LIST = 'mcp_list_forms';
  MCPFORMS_ACTION_DESCRIBE = 'mcp_describe_form';
  MCPFORMS_ACTION_FILL = 'mcp_fill_form';

type
  /// The skill "mcpforms". Registered with HelpChatAI when the unit is used.
  TMCPFormsHelpChatSkill = class(THelpChatSkill)
  private
    function ResultLimit: Integer;
  protected
    procedure RegisterActions; override;
  public
    class function SkillName: string; override;
    class function SkillDescription(const ALanguage: THelpChatLanguage = hclAuto): string; override;
    /// True for any assistant: the skill works through ModelContext.
    class function Supports(const AHost: TComponent): Boolean; override;
  end;

/// The text of mcp_list_forms. Main thread.
function MCPHelpChatListForms(MaxChars: Integer = 0): string;
/// The text of mcp_describe_form. Raises EMCPToolError when there is no such
/// form tool. Main thread.
function MCPHelpChatDescribeForm(const FormName: string; MaxChars: Integer = 0): string;
/// What mcp_fill_form does: fills the form, never submits it, returns what
/// the model is told. Raises EMCPToolError with a message the model can act
/// on. Main thread.
function MCPHelpChatFillForm(const FormName: string; Values: TJSONObject): string;

implementation

uses
  System.StrUtils, System.Math;

const
  ENUM_FULL = 30;
  ENUM_SHORT = 10;

{ Helpers }

function OneLine(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] < ' ' then
      Result[I] := ' ';
  Result := Trim(Result);
end;

function Cut(const S: string; MaxChars: Integer): string;
begin
  Result := OneLine(S);
  if (MaxChars > 0) and (Length(Result) > MaxChars) then
    Result := Copy(Result, 1, MaxChars) + '...';
end;

/// The form tool by name, else by title (models often use the title).
function TryFindTool(const FormName: string): TMCPCustomFormTool;
var
  T: TMCPCustomFormTool;
begin
  Result := MCPFindFormTool(FormName);
  if Result <> nil then
    Exit;
  for T in MCPRegisteredFormTools do
    if (T.ToolTitle <> '') and SameText(Trim(T.ToolTitle), Trim(FormName)) then
      Exit(T);
end;

/// TryFindTool, or the error the model reads.
function FindTool(const FormName: string): TMCPCustomFormTool;
var
  T: TMCPCustomFormTool;
  Names: string;
begin
  Result := TryFindTool(FormName);
  if Result <> nil then
    Exit;
  Names := '';
  for T in MCPRegisteredFormTools do
    Names := Names + IfThen(Names <> '', ', ') + '"' + T.RegisteredName + '"';
  if Names = '' then
    raise EMCPToolError.CreateFmt('There is no form named "%s": no form of the ' +
      'application can be filled right now.', [Cut(FormName, 60)]);
  raise EMCPToolError.CreateFmt('There is no form named "%s". Use one of: %s.',
    [Cut(FormName, 60), Names]);
end;

function TitleOf(T: TMCPCustomFormTool): string;
begin
  Result := T.ToolTitle;
  if Result = '' then
    Result := T.RegisteredName;
end;

function PropSchema(Schema: TJSONObject; const Name: string): TJSONObject;
var
  Props: TJSONObject;
begin
  Result := nil;
  if (Schema <> nil) and Schema.TryGetValue<TJSONObject>('properties', Props) then
    if not Props.TryGetValue<TJSONObject>(Name, Result) then
      Result := nil;
end;

/// What the user reads for a parameter: its title, the short form of its
/// description, or its name.
function ParamLabel(Prop: TJSONObject; const Name: string): string;
var
  S: string;
begin
  Result := '';
  if Prop <> nil then
  begin
    if Prop.TryGetValue<string>('title', S) then
      Result := OneLine(S);
    if (Result = '') and Prop.TryGetValue<string>('description', S) then
      Result := HelpChatShortLabel(OneLine(S));
  end;
  if Result = '' then
    Result := Name;
end;

function IsRequired(Schema: TJSONObject; const Name: string): Boolean;
var
  Req: TJSONArray;
  V: TJSONValue;
begin
  Result := False;
  if (Schema <> nil) and Schema.TryGetValue<TJSONArray>('required', Req) then
    for V in Req do
      if V.Value = Name then
        Exit(True);
end;

function QuotedList(A: TJSONArray; MaxItems: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Min(A.Count, MaxItems) - 1 do
    Result := Result + IfThen(I > 0, ', ') + '"' + Cut(HelpChatJsonValueText(A.Items[I]), 60) + '"';
  if A.Count > MaxItems then
    Result := Result + Format(' and %d more', [A.Count - MaxItems]);
end;

/// The type of a parameter as the model is told, in the words of the
/// "forms" skill of HelpChatAI.
function TypeText(Prop: TJSONObject; MaxEnum: Integer): string;
var
  JsonType, Fmt, Pattern: string;
  A: TJSONArray;
  MinV, MaxV: TJSONValue;
  N: Integer;
begin
  if Prop = nil then
    Exit('any value');
  if Prop.TryGetValue<TJSONArray>('enum', A) then
    Exit('one of: ' + QuotedList(A, MaxEnum));
  JsonType := '';
  Prop.TryGetValue<string>('type', JsonType);
  if JsonType = 'array' then
    Exit('a list that can only be read, never filled')
  else if JsonType = 'boolean' then
    Exit('yes/no (true or false)')
  else if (JsonType = 'integer') or (JsonType = 'number') then
  begin
    if JsonType = 'integer' then
      Result := 'integer number'
    else
      Result := 'decimal number (use "." as decimal separator)';
    MinV := Prop.GetValue('minimum');
    MaxV := Prop.GetValue('maximum');
    if (MinV <> nil) and (MaxV <> nil) then
      Result := Result + Format(' from %s to %s', [MinV.Value, MaxV.Value])
    else if MinV <> nil then
      Result := Result + ' from ' + MinV.Value
    else if MaxV <> nil then
      Result := Result + ' up to ' + MaxV.Value;
    Exit;
  end;
  Fmt := '';
  Prop.TryGetValue<string>('format', Fmt);
  Pattern := '';
  Prop.TryGetValue<string>('pattern', Pattern);
  if Fmt = 'date' then
    Result := 'date (YYYY-MM-DD)'
  else if Fmt = 'date-time' then
    Result := 'date and time (YYYY-MM-DDTHH:MM)'
  else if (Fmt = 'time') or ContainsStr(Pattern, ':') then
    Result := 'time (HH:MM)'
  else
  begin
    Result := 'text';
    if Prop.TryGetValue<Integer>('maxLength', N) and (N > 0) then
      Result := Format('text, max %d characters', [N]);
    if Prop.TryGetValue<TJSONArray>('examples', A) and (A.Count > 0) then
      Result := Result + '; usual values: ' + QuotedList(A, Min(MaxEnum, 20));
  end;
end;

function DescribeText(T: TMCPCustomFormTool; MaxEnum: Integer; WithHints: Boolean): string;
var
  Schema, Prop: TJSONObject;
  Props: TJSONObject;
  Pair: TJSONPair;
  SB: TStringBuilder;
  Name, Lbl, Desc, Flags: string;
  B: Boolean;
begin
  Schema := T.NewInputSchema;
  SB := TStringBuilder.Create;
  try
    SB.AppendFormat('Form "%s" (%s)', [T.RegisteredName, OneLine(TitleOf(T))]);
    if T.Available then
      SB.Append(', open now.')
    else
      SB.Append(', not open right now: the user has to open it before it can be filled.');
    SB.AppendLine;
    SB.AppendLine(Cut(T.ToolDescription, 400));
    if not Schema.TryGetValue<TJSONObject>('properties', Props) or (Props.Count = 0) then
      SB.AppendLine('It has no fields.')
    else
    begin
      SB.AppendLine('Fields (name | label | type | flags), then the full description:');
      for Pair in Props do
      begin
        Name := Pair.JsonString.Value;
        if Pair.JsonValue is TJSONObject then
          Prop := TJSONObject(Pair.JsonValue)
        else
          Prop := nil;
        Lbl := ParamLabel(Prop, Name);
        if IsRequired(Schema, Name) then
          Flags := 'required'
        else
          Flags := 'optional';
        if (Prop <> nil) and Prop.TryGetValue<Boolean>('readOnly', B) and B then
          Flags := 'read-only';
        SB.AppendFormat('- %s | %s | %s | %s', [Name, Lbl, TypeText(Prop, MaxEnum), Flags]).AppendLine;
        Desc := '';
        if WithHints and (Prop <> nil) and Prop.TryGetValue<string>('description', Desc) then
        begin
          Desc := Cut(Desc, 200);
          if (Desc <> '') and not SameText(Desc, Lbl) then
            SB.Append('  ').AppendLine(Desc);
        end;
      end;
    end;
    SB.Append(MCPFORMS_ACTION_FILL + ' fills it with {"name": value}: give the values the ' +
      'user gave, required or not; the user completes the rest on screen. The user confirms ' +
      'the values first; nothing is saved: the user reviews the form and saves it.');
    Result := SB.ToString;
  finally
    SB.Free;
    Schema.Free;
  end;
end;

{ Public helpers }

function MCPHelpChatListForms(MaxChars: Integer): string;

  function Build(DescChars: Integer): string;
  var
    T: TMCPCustomFormTool;
    SB: TStringBuilder;
  begin
    SB := TStringBuilder.Create;
    try
      SB.AppendLine('Forms of the application the assistant can fill (name | title | state | what it is for):');
      for T in MCPRegisteredFormTools do
        SB.AppendFormat('- %s | %s | %s | %s', [T.RegisteredName, Cut(TitleOf(T), 80),
          IfThen(T.Available, 'open', 'not open'), Cut(T.ToolDescription, DescChars)]).AppendLine;
      SB.Append(MCPFORMS_ACTION_DESCRIBE + ' gives the fields of one, ' + MCPFORMS_ACTION_FILL +
        ' fills it. A form that is not open must be opened by the user first.');
      Result := SB.ToString;
    finally
      SB.Free;
    end;
  end;

begin
  if Length(MCPRegisteredFormTools) = 0 then
    Exit('No form of this application can be filled by the assistant right now.');
  Result := Build(300);
  if (MaxChars > 0) and (Length(Result) > MaxChars) then
    Result := Build(80);
  if (MaxChars > 0) and (Length(Result) > MaxChars) then
    Result := Build(0);
end;

function MCPHelpChatDescribeForm(const FormName: string; MaxChars: Integer): string;
var
  T: TMCPCustomFormTool;
begin
  T := FindTool(FormName);
  Result := DescribeText(T, ENUM_FULL, True);
  if (MaxChars > 0) and (Length(Result) > MaxChars) then
    Result := DescribeText(T, ENUM_SHORT, True);
  if (MaxChars > 0) and (Length(Result) > MaxChars) then
    Result := DescribeText(T, ENUM_SHORT, False);
end;

function MCPHelpChatFillForm(const FormName: string; Values: TJSONObject): string;
var
  T: TMCPCustomFormTool;
  Schema: TJSONObject;
  Pair: TJSONPair;
  Filled, Empty: string;
  Name: string;
begin
  if Values = nil then
    raise EMCPToolError.Create('"values" must be a JSON object {"name": value} with ' +
      'the field names of ' + MCPFORMS_ACTION_DESCRIBE + '.');
  T := FindTool(FormName);
  // a form that is not open: Fill says so, which matters more
  if (Values.Count = 0) and T.Available then
    raise EMCPToolError.CreateFmt('No values to fill: give at least one field of "%s" ' +
      '(%s lists them).', [T.RegisteredName, MCPFORMS_ACTION_DESCRIBE]);
  Empty := '';
  Schema := T.NewInputSchema;
  try
    for Name in T.Fill(Values) do
      Empty := Empty + IfThen(Empty <> '', ', ') + ParamLabel(PropSchema(Schema, Name), Name);
    Filled := '';
    for Pair in Values do
      Filled := Filled + IfThen(Filled <> '', ', ') +
        ParamLabel(PropSchema(Schema, Pair.JsonString.Value), Pair.JsonString.Value);
  finally
    Schema.Free;
  end;
  Result := Format('"%s": %d field(s) filled (%s). Nothing was saved: the form is in ' +
    'front of the user, highlighted, and the user reviews the values and saves it, or ' +
    'cancels. Do not say it was saved.', [OneLine(TitleOf(T)), Values.Count, Filled]);
  if Empty <> '' then
    Result := Result + ' Still empty, the user must fill: ' + Empty + '.';
end;

{ TMCPFormsHelpChatSkill }

class function TMCPFormsHelpChatSkill.SkillName: string;
begin
  Result := MCPFORMS_SKILL_NAME;
end;

class function TMCPFormsHelpChatSkill.SkillDescription(const ALanguage: THelpChatLanguage): string;
begin
  case HelpChatResolveLanguage(ALanguage) of
    hclItalian:
      Result := 'Elenca le schede dell''applicazione che l''assistente puo'' compilare e ' +
        'ne compila una, chiedendo prima e senza mai salvare.';
  else
    Result := 'Lists the forms of the application the assistant can fill and fills one, ' +
      'asking first and never saving.';
  end;
end;

class function TMCPFormsHelpChatSkill.Supports(const AHost: TComponent): Boolean;
begin
  Result := True;
end;

function TMCPFormsHelpChatSkill.ResultLimit: Integer;
begin
  if Broker <> nil then
    Result := Broker.ResultMaxChars
  else
    Result := 0;
end;

procedure TMCPFormsHelpChatSkill.RegisterActions;
var
  LAction: THelpChatAction;
begin
  AddAction(MCPFORMS_ACTION_LIST,
    'Lists the forms of the application the assistant can fill, open or not: for each ' +
    'its name, title, whether it is open now and what it is for. Use it when the user ' +
    'asks to enter data that belongs to a form other than the one in front of them, then ' +
    MCPFORMS_ACTION_DESCRIBE + ' and ' + MCPFORMS_ACTION_FILL + '.',
    [],
    procedure(const AArgs: THelpChatActionArgs; var AResult: string)
    begin
      AResult := MCPHelpChatListForms(ResultLimit);
    end, False);

  AddAction(MCPFORMS_ACTION_DESCRIBE,
    'Describes one form of ' + MCPFORMS_ACTION_LIST + ': for each field its name, label, ' +
    'type, the allowed values and whether it is required, then its full description. ' +
    'Call it before ' + MCPFORMS_ACTION_FILL + ' and follow the descriptions of the fields.',
    [THelpChatActionParam.Create('form', 'Name of the form, as listed by ' +
      MCPFORMS_ACTION_LIST + '.')],
    procedure(const AArgs: THelpChatActionArgs; var AResult: string)
    begin
      AResult := MCPHelpChatDescribeForm(AArgs.AsString('form'), ResultLimit);
    end, False);

  LAction := AddAction(MCPFORMS_ACTION_FILL,
    'Fills a form of ' + MCPFORMS_ACTION_LIST + ' with the field names of ' +
    MCPFORMS_ACTION_DESCRIBE + ', brings it in front of the user and highlights it. The ' +
    'form must be open. Give the values the user gave, even if required fields are ' +
    'missing: the result lists the required fields still empty, which the user fills on ' +
    'screen - tell the user. The user is asked to confirm the values. It never saves: the ' +
    'user reviews the values and saves. On an error the fields are put back as they were ' +
    '(the error names any that could not be): correct the values and call it again.',
    [THelpChatActionParam.Create('form', 'Name of the form, as listed by ' +
      MCPFORMS_ACTION_LIST + '.'),
     THelpChatActionParam.Create('values',
      'JSON object {"field name": value} with the names of ' + MCPFORMS_ACTION_DESCRIBE +
      '. Dates as YYYY-MM-DD, times as HH:MM, numbers with "." as decimal separator, ' +
      'yes/no as true/false, choices exactly as listed.')],
    procedure(const AArgs: THelpChatActionArgs; var AResult: string)
    var
      LValues: TJSONObject;
    begin
      LValues := HelpChatSkillValues(AArgs.RawJson);
      try
        AResult := MCPHelpChatFillForm(AArgs.AsString('form'), LValues);
      finally
        LValues.Free;
      end;
    end, True);
  if Assigned(LAction) then
    // The confirmation reads the title of the form and "Guest name: Mario",
    // not a JSON object.
    LAction.OnDisplay :=
      procedure(const AArgs: THelpChatActionArgs; var ASummary: string;
        var AValues: TArray<TPair<string, string>>)
      var
        LTool: TMCPCustomFormTool;
        LValues, LSchema: TJSONObject;
        LPair: TJSONPair;
      begin
        LTool := TryFindTool(AArgs.AsString('form'));
        LValues := HelpChatSkillValues(AArgs.RawJson);
        LSchema := nil;
        try
          if LTool = nil then
            Exit; // the fill reports the error: show what the model sent
          ASummary := HelpChatMsgFmt(hcmSkillFill, [OneLine(TitleOf(LTool))]);
          if LValues = nil then
            Exit;
          LSchema := LTool.NewInputSchema;
          AValues := nil;
          for LPair in LValues do
            AValues := AValues + [TPair<string, string>.Create(
              ParamLabel(PropSchema(LSchema, LPair.JsonString.Value), LPair.JsonString.Value),
              HelpChatJsonValueText(LPair.JsonValue))];
        finally
          LSchema.Free;
          LValues.Free;
        end;
      end;
end;

initialization
  HelpChatRegisterSkill(TMCPFormsHelpChatSkill);

finalization
  HelpChatUnregisterSkill(TMCPFormsHelpChatSkill);

end.
