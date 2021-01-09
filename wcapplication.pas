unit wcapplication;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  StringHashList,
  SysUtils, DateUtils,
  ECommonObjs,
  fpwebfile, fpmimetypes,
  fphttp, HTTPDefs, httpprotocol, http2consts,
  abstracthttpserver, wchttp2server,
  custweb, custabshttpapp,
  sqlitewebsession,
  sqlitelogger,
  jsonscanner, jsonparser, fpjson,
  ExtSqlite3DS,
  variants,
  sockets,
  ssockets,
  gzstream,
  BufferedStream,
  kcThreadPool,
  SortedThreadPool,
  AvgLvlTree
  {$ifdef NOGUI}
  {$ifdef unix}
  , gwidgetsethelper
  {$endif}
  {$endif}    ;

type

  TWebClient = class;
  TWebClients = class;
  TWCResponse = class;
  TWCRequest = class;
  TWCConnection = class;
  TWCHTTPServer = class;
  TWebClientClass = class of TWebClient;

  { TWCConnection }

  TWCConnection =  class(TWCHTTPConnection)
  private
    FInputBuf : Pointer;
    FInput    : TBufferedStream;
    FResponse : TWCResponse;
    FRequest  : TWCRequest;
    FClient   : TWebClient;
    FSession  : TSqliteWebSession;
    FProtocolVersion : TWCProtocolVersion;
    procedure DoInitialize;
  protected
    function ReadLine : String;
    Function ReadReqHeaders : TWCRequest;
    function ConvertFromHTTP2Req(AReq2 : TWCHTTP2Request) : TWCRequest;
    procedure ReadReqContent(ARequest: TWCRequest);
    procedure ConsumeHeader(ARequest: TRequest; AHeader: String); override;
    procedure UnknownHeader(ARequest: TRequest; const AHeader: String); override;
    procedure DoSocketAttach(ASocket : TSocketStream); override;
  public
    Constructor Create(AServer : TAbsCustomHTTPServer; ASocket : TSocketStream); override;
    Constructor CreateRefered(AServer : TAbsCustomHTTPServer; ASocketRef : TWCHTTPSocketReference); override;
    function ConsumeSocketData : Boolean;
    procedure SetSessionParams(aClient : TWebClient; aSession : TSqliteWebSession);
    destructor Destroy; override;
    property Response : TWCResponse read FResponse;
    property Request : TWCRequest read FRequest;
    property Client : TWebClient read FClient;
    property Session : TSqliteWebSession read FSession;
    property HTTPVersion : TWCProtocolVersion read FProtocolVersion;
  end;

  { TWCMainClientJob }

  TWCMainClientJob = class(TSortedJob)
  private
    FConn : TWCConnection;
    FResponseReadyToSend : Boolean;
    function GetClient: TWebClient;
    function GetRequest: TWCRequest;
    function GetResponse: TWCResponse;
  public
    P1, P2 : Variant;
    constructor Create(aConn : TWCConnection);
    destructor Destroy; override;
    procedure Execute; override;
    procedure ReleaseConnection;
    property  Connection : TWCConnection read FConn;
    property  Request : TWCRequest read GetRequest;
    property  Response : TWCResponse read GetResponse;
    property  Client : TWebClient read GetClient;
    property  ResponseReadyToSend : Boolean read FResponseReadyToSend write
                                                 FResponseReadyToSend;
  end;
  TWCMainClientJobClass = class of TWCMainClientJob;

  { TWCPreAnalizeClientJob }

  TWCPreAnalizeClientJob = class(TJob)
  private
    FConn : TWCConnection;
    function GetRequest: TWCRequest;
    function GetResponse: TWCResponse;
  public
    constructor Create(aConn : TWCConnection);
    destructor Destroy; override;
    procedure Execute; override;
    function GenerateClientJob : TWCMainClientJob; virtual;
    property Connection : TWCConnection read FConn;
    property Request : TWCRequest read GetRequest;
    property Response : TWCResponse read GetResponse;
  end;
  TWCPreAnalizeClientJobClass = class of TWCPreAnalizeClientJob;

  { TWCHttpServer }

  TWCHttpServer = class(TEmbeddedAbsHttpServer)
  private
    FMaxPreClientsThreads, FMaxMainClientsThreads : Byte;
    FPreThreadPool : TThreadPool;
    FMainThreadPool : TSortedThreadPool;
    FPoolsLocker : TNetCustomLockedObject;
    FHTTP2Connections : TWCHTTP2Connections;
    procedure SetMaxMainClientsThreads(AValue: Byte);
    procedure SetMaxPreClientsThreads(AValue: Byte);
    function CompareMainJobs(Tree: TAvgLvlTree; Data1, Data2: Pointer) : Integer;
    procedure AddToMainPool(AJob : TWCMainClientJob);
  public
    constructor Create(AOwner: TComponent); override;
    function CreateSSLSocketHandler: TSocketHandler; override;
    Procedure CreateConnectionThread(Conn : TAbsHTTPConnection); override;
    function  CreateConnection(Data : TSocketStream) : TAbsHTTPConnection; override;
    Function  CreateRequest : TAbsHTTPConnectionRequest; override;
    Function  CreateResponse(ARequest : TAbsHTTPConnectionRequest) : TAbsHTTPConnectionResponse; override;
    Procedure InitRequest(ARequest : TAbsHTTPConnectionRequest); override;
    Procedure InitResponse(AResponse : TAbsHTTPConnectionResponse); override;
    function AttachNewHTTP2Con(aSocket: TWCHTTPSocketReference;
                               aOpenMode: THTTP2OpenMode;
                               aServerDoConsume : THttp2SocketConsume): TWCHTTP2Connection;
    property  MaxPreClientsThreads : Byte read FMaxPreClientsThreads write SetMaxPreClientsThreads;
    property  MaxMainClientsThreads : Byte read FMaxMainClientsThreads write SetMaxMainClientsThreads;
    function  ServerActive : Boolean;
    procedure DoConnectToSocketRef(SockRef : TWCHTTPSocketReference);
    destructor Destroy; override;

    property  HTTP2Connections : TWCHTTP2Connections read FHTTP2Connections;
  end;

  { TWCHttpServerHandler }

  TWCHttpServerHandler = class(TAbsHTTPServerHandler)
  public
    Function CreateServer : TEmbeddedAbsHttpServer; override;
    function GetESServer : TWCHttpServer;
  end;

  { TWCHTTPApplication }

  TWCHTTPApplication = Class(TCustomAbsHTTPApplication)
  private
    FCompressLimit: Cardinal;
    FMaxMainThreads: Byte;
    FMaxPrepareThreads: Byte;
    FMimeLoc: String;
    FMTime : QWord;
    FLogDB : TSqliteLogger;
    FSocketsReferences, FReferences : TNetReferenceList;
    FStartStamp : QWord;
    FNetDebugMode : Boolean;
    FWebClientClass :  TWebClientClass;
    FServerAnalizeJobClass : TWCPreAnalizeClientJobClass;
    FMainHTTP, FSessionsLoc, FSessionsDb, FLogDbLoc,
    FWebFilesLoc, FSSLLoc : String;
    procedure DoOnException(Sender : TObject; E : Exception);
    Procedure DoGetModule(Sender : TObject; ARequest : TRequest;
                               Var ModuleClass : TCustomHTTPModuleClass);
    procedure DoOnIdle(sender : TObject);
    function GetESServer: TWCHttpServer;
    procedure SetMaxMainThreads(AValue: Byte);
    procedure SetMaxPrepareThreads(AValue: Byte);
    procedure SetSSLLoc(AValue: String);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure DoInfo(const V : String); overload;
    procedure DoInfo(const V : String; const aParams : Array Of const); overload;
    procedure DoError(const V : String); overload;
    procedure DoError(const V : String; const aParams : Array Of const); overload;
    procedure SendError(AResponse: TResponse; errno: Integer);
    Procedure Initialize; override;
    function GetWebHandler: TWCHttpServerHandler;
    function InitializeAbstractWebHandler : TWebHandler; override;
    function GetTimeSecFromStart : Cardinal;
    property ESServer : TWCHttpServer read GetESServer;
    property GarbageCollector : TNetReferenceList read FReferences;
    property SocketsCollector : TNetReferenceList read FSocketsReferences;
    property NetDebugMode : Boolean read FNetDebugMode;
    property WebClientClass : TWebClientClass read FWebClientClass write FWebClientClass;
    property ServerAnalizeJobClass : TWCPreAnalizeClientJobClass read FServerAnalizeJobClass write FServerAnalizeJobClass;
    property MainURI : String read FMainHTTP write FMainHTTP;
    property SessionsLoc : String read FSessionsLoc write FSessionsLoc;
    property SessionsDb : String read FSessionsDb write FSessionsDb;
    property LogDb : String read FLogDbLoc write FLogDbLoc;
    property MimeLoc : String read FMimeLoc write FMimeLoc;
    property SSLLoc : String read FSSLLoc write SetSSLLoc;
    property WebFilesLoc : String read FWebFilesLoc write FWebFilesLoc;
    property CompressLimit : Cardinal read FCompressLimit write FCompressLimit;
    property MaxPrepareThreads : Byte read FMaxPrepareThreads write SetMaxPrepareThreads;
    property MaxMainThreads : Byte read FMaxMainThreads write SetMaxMainThreads;
  end;

  { TWebCachedItem }

  TWebCachedItem = class(TNetCustomLockedObject)
  private
    FDataTime : TDateTime;
    FCache, FDeflateCache : TMemoryStream;
    FNeedToCompress : Boolean;
    FDeflateSize: QWord;
    {$IFDEF ALLOW_STREAM_GZIP}
    FGzipSize: QWord;
    FGzipCache : TMemoryStream;
    {$ENDIF}
    FSize : QWord;
    FLoc : String;
    FMimeType : String;
    FCacheControl : String;
    function GetCache: TMemoryStream;
    function GetDeflateCache: TMemoryStream;
    function GetDeflateReady: Boolean;
    function GetDeflateSize: QWord;
    {$IFDEF ALLOW_STREAM_GZIP}
    function GetGzipCache: TMemoryStream;
    function GetGzipReady: Boolean;
    function GetGzipSize: QWord;
    {$ENDIF}
    function GetMimeType: String;
    function GetSize: QWord;
  public
    constructor Create(const aLoc : String);
    destructor Destroy; override;
    procedure Clear;
    procedure Refresh;
    property Cache : TMemoryStream read GetCache;
    property Size : QWord read GetSize;
    property DeflateCache : TMemoryStream read GetDeflateCache;
    property DeflateSize : QWord read GetDeflateSize;
    property DeflateReady : Boolean read GetDeflateReady;
    {$IFDEF ALLOW_STREAM_GZIP}
    property GzipCache : TMemoryStream read GetGzipCache;
    property GzipSize : QWord read GetGzipSize;
    property GzipReady : Boolean read GetGzipReady;
    {$ENDIF}
    property MimeType : String read GetMimeType;
    property CacheControl : String read FCacheControl;
  end;


  { TWebCacheCollection }

  TWebCacheCollection = class(TThreadSafeFastCollection)
  private
    FHash : TStringHashList;
    function GetCache(const index : String): TWebCachedItem;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear; override;
    procedure AddNew(const aName: String; aData: TWebCachedItem);
    property CacheItem[const index : String] : TWebCachedItem read GetCache; default;
  end;

  TWebHashState = record
    SavedState : String;
    HashValue  : Cardinal;
  end;

  TWebClientState = Byte;

  { TWebThreadSafeCacheStates }

  TWebThreadSafeCacheStates = class(TNetCustomLockedObject)
  private
    FCurState : Array of TWebHashState;
    function GetStateHash(index : TWebClientState): Cardinal;
    function GetStateValue(index : TWebClientState): String;
    procedure SetStateHash(index : TWebClientState; AValue: Cardinal);
    procedure SetStateValue(index : TWebClientState; const AValue: String);
  public
    procedure SetStatesLength(Len : integer);
    property Hash[index : TWebClientState] : Cardinal read GetStateHash
                                                 write SetStateHash;
    property Value[index : TWebClientState] : String read GetStateValue
                                                 write SetStateValue;
  end;

  { TWebClient }

  TWebClient = class(TNetReferencedObject)
  private
    FCUID : String;
    FCurStates : TWebThreadSafeCacheStates;
    FOwner : TWebClients;
    FAcceptGZip : TThreadBoolean;
    FAcceptDeflate : TThreadBoolean;
    FHasSynConnection : TThreadBoolean;
    FOnRemove : TNotifyEvent;
    FStartStamp : QWord;
    FScore : TThreadInteger;
    FLastConnection : TThreadInteger;
    function GetAcceptGZip: Boolean;
    function GetLastConnection: Integer;
    function GetScore: Integer;
    function GetStateHash(index : TWebClientState): Cardinal;
    procedure SetAcceptGZip(AValue: Boolean);
    function GetAcceptDeflate: Boolean;
    procedure SetAcceptDeflate(AValue: Boolean);
    function GetHasSynConnection: Boolean;
    procedure SetHasSynConnection(AValue: Boolean);
    procedure SetScore(AValue: Integer);
  protected
    function GenerateNewStateHash : Cardinal;
    property CurStates : TWebThreadSafeCacheStates read FCurStates;
  public
    constructor Create(AOwner : TWebClients; const aCUID : String); virtual;
    destructor Destroy; override;
    procedure DoIdle; virtual;
    procedure UpdateScore; virtual;
    procedure RelaxScore;  virtual;
    procedure Initialize;  virtual;
    function SaveNewState(aState: TWebClientState; const aNewState: String;
      oldHash: Cardinal; ignoreHash: boolean=false): Boolean;
    procedure ResponseString(AResponse : TResponse; const S : String); virtual;
    property CUID : String read FCUID;
    property StateHash[index : TWebClientState] : Cardinal read GetStateHash;
    property AcceptGzip : Boolean read GetAcceptGZip write SetAcceptGZip;
    property AcceptDeflate : Boolean read GetAcceptDeflate write SetAcceptDeflate;
    property HasSynConnection : Boolean read GetHasSynConnection write SetHasSynConnection;
    property OnRemove : TNotifyEvent read FOnRemove write FOnRemove;
    property LastConnectionInSec : Integer read GetLastConnection;
    property Score : Integer read GetScore write SetScore;
  end;

  TWebClientsContainer = class;

  { TWebClients }

  TWebClients = class(TThreadSafeFastSeq)
  private
    FContainer : TWebClientsContainer;
    FHash : TStringHashList;
    function  GetClient(const cUID : String): TWebClient;
    function  IsClientDead(aClient : TObject; data : pointer) : Boolean;
    procedure AfterClientExtracted(aObj : TObject);
    procedure IdleClient(aObj : TObject);
  public
    constructor Create(aContainer : TWebClientsContainer);
    destructor Destroy; override;
    procedure Clear;
    procedure AddNew(const cUID: String; aClient: TWebClient);
    procedure RemoveClient(aClient : TWebClient); overload;
    procedure RemoveClient(const cUID: String); overload;
    procedure RemoveClientNotDestroy(const cUID: String);
    procedure ClearDeadClients;
    procedure IdleLiveClients;
    property  Client[const cUID : String] : TWebClient read GetClient; default;
    property  Container : TWebClientsContainer read FContainer;
  end;


  { TWebClientsContainer }

  TWebClientsContainer = class(TNetCustomLockedObject)
  private
    FSessions : TSqliteSessionFactory;
    FCachedPages : TWebCacheCollection;
    FClientsDB : TExtSqlite3Dataset;
    PREP_AddClientToBase,
    PREP_ClientStop,
    PREP_ClientSetLastCUID,
    PREP_ClientGetLastCUID,
    PREP_OnCreateSession,
    PREP_DeleteOldNetRequests : TSqlite3Prepared;
    //
    FCurCID : TThreadSafeAutoIncrementCardinal;
    FConnectedClients : TWebClients;
    procedure ClientRemove(Sender : TObject);
    function OnGenSessionID(aSession : TSqliteWebSession) : String;
  public
    constructor Create;
    destructor Destroy; override;
    procedure  ClearCache;
    function CreateSession(ARequest : TWCRequest) : TSqliteWebSession;
    //
    procedure OnCreateNewSession(Sender : TObject);
    function  AddClient(ARequest : TRequest; const ClientID : String): TWebClient;
    function  GetClient(const ClientID : String) : TWebClient;
    procedure RemoveClient(const ClientID : String); overload;
    procedure RemoveClient(mClient : TWebClient); overload;
    procedure ClearDeadClients;
    procedure DoMaintainingStep;
    //
    function  GetWebCachedItem(const aLoc : String) : TWebCachedItem;
    //
    property  Sessions : TSqliteSessionFactory read FSessions;
    property  Clients  : TWebClients read FConnectedClients;
  end;

  { TWCResponse }

  TWCResponse = class (TAbsHTTPConnectionResponse)
  private
    FKeepAlive : boolean;
    function  GetConnection : TWCConnection;
  public
    procedure SendUTf8String(const S: String);
    procedure CloseStream;
    Procedure DoSendHeaders(Headers : TStrings); override;
    Procedure DoSendContent; override;
    property  WCConn : TWCConnection read GetConnection;
    property  KeepStreamAlive : Boolean read FKeepAlive write FKeepAlive;
  end;

  { TWCRequest }

  TWCRequest = class (TAbsHTTPConnectionRequest)
  private
    function GetSocket: TSocketStream;
    function GetConnection : TWCConnection;
  public
    procedure CollectHeaders(Headers : TStringList);
    property  WCConn : TWCConnection read GetConnection;
    property  Socket : TSocketStream read GetSocket;
  end;

var
  vPath : unicodestring;// = '/webclient';
  WebContainer : TWebClientsContainer;

const
{$ifdef unix}
cSysDelimiter = '/';
cNonSysDelimiter = '\';
{$else}
cSysDelimiter = '\';
cNonSysDelimiter = '/';
{$endif}

Var
  Application : TWCHTTPApplication;
  ShowCleanUpErrors : Boolean = False;

function ESWGetHeaderContent(H : THTTPHeader; const P1S, P2S : String;
                              out Par1, Par2 : Variant;
                              const Def1, Def2 : Variant) : Boolean; overload;
function ESWGetHeaderContent(H : THTTPHeader; const PS : String;
                              out Par : Variant;
                              const Def : Variant) : Boolean; overload;
function EncodeIntToSID(value : Cardinal; Digits : integer) : String;
function EncodeInt64ToSID(value : QWORD; Digits : integer) : String;
function DecodeSIDToInt(const value : String) : Cardinal;
Function ESSocketAddrToString(ASocketAddr: TSockAddr): String;
function ESGetGetRemoteAddress(Handle : Cardinal): sockets.TSockAddr;

const
  cSgzip = 'gzip';
  cSdeflate = 'deflate';

  WC_MAX_MAIN_THREADS = 32;
  WC_MAX_PREP_THREADS = 32;

Implementation

uses  CustApp, extopensslsockets, math;
const WCSocketReadError = 'Socket read error';
const sidEncodeTable : Array [0..63] of Char =
                                       ('0','1','2','3','4','5','6','7','8','9',
                                        'a','b','c','d','e','f','g','h','i','j',
                                        'k','l','m','n','o','p','q','r','s','t',
                                        'u','v','w','x','y','z','A','B','C','D',
                                        'E','F','G','H','I','J','K','L','M','N',
                                        'O','P','Q','R','S','T','U','V','W','X',
                                        'Y','Z','~','_');

function EncodeIntToSID(value : Cardinal; Digits : integer) : String;
var i: integer;
begin
 If Digits=0 then
   Digits:=1;
 SetLength(result, digits);
 for i := 0 to digits - 1 do
  begin
   result[digits - i] := sidEncodeTable[value and 63];
   value := value shr 6;
  end ;
 while value <> 0 do begin
   result := sidEncodeTable[value and 63] + result;
   value := value shr 6;
 end;
end;

function EncodeInt64ToSID(value : QWORD; Digits : integer) : String;
var i: integer;
begin
 If Digits=0 then
   Digits:=1;
 SetLength(result, digits);
 for i := 0 to digits - 1 do
  begin
   result[digits - i] := sidEncodeTable[value and 63];
   value := value shr 6;
  end ;
 while value <> 0 do begin
   result := sidEncodeTable[value and 63] + result;
   value := value shr 6;
 end;
end;

function DecodeSIDToInt(const value : String) : Cardinal;
var i, k : integer;
    C : AnsiChar;
begin
  Result := 0;
  k := 0;
  for i := Length(value) downto 1 do
  begin
    C := value[i];
    if (C >= '0') and (C <= '9') then Result := Result or ((Ord(C) - Ord('0')) shl k) else
    if (C >= 'a') and (C <= 'z') then Result := Result or ((Ord(C) - Ord('a') + 10) shl k) else
    if (C >= 'A') and (C <= 'Z') then Result := Result or ((Ord(C) - Ord('A') + 36) shl k) else
    if C = '~' then Result := Result or (62 shl k) else
    if C = '_' then Result := Result or (63 shl k);
    Inc(k, 6);
  end;
end;

function ESWGetHeaderContent(H : THTTPHeader; const P1S, P2S : String;
                              out Par1, Par2 : Variant;
                              const Def1, Def2 : Variant) : Boolean;
var jsonObj: TJSONObject;
  jsonData1, jsonData2 : TJSONData;
begin
  Result := false;
  try
    jsonObj:= TJSONObject(GetJSON(H.Content));
    if assigned(jsonObj) then
    begin
      jsonData1 := jsonObj.Find(P1S);
      jsonData2 := jsonObj.Find(P2S);
      if Assigned(jsonData1) and Assigned(jsonData2) then
      begin
        If jsonData1.JSONType = jtObject then
          Par1 := TJSONObject(jsonData1).AsJSON else
          Par1 := jsonData1.Value;
        if VarIsNull(Par1) then Par1 := Def1;
        If jsonData2.JSONType = jtObject then
          Par2 := TJSONObject(jsonData2).AsJSON else
          Par2 := jsonData2.Value;
        if VarIsNull(Par2) then Par2 := Def2;
      end;
      Result := (((VarIsNumeric(Par2) and VarIsNumeric(Def2)) or
                  (VarIsStr(Par2) and VarIsStr(Def2)))) and
                (((VarIsNumeric(Par1) and VarIsNumeric(Def1)) or
                  (VarIsStr(Par1) and VarIsStr(Def1)))) ;
    end;
  finally
    if assigned(jsonObj) then FreeAndNil(jsonObj);
  end;
end;

function ESWGetHeaderContent(H: THTTPHeader; const PS: String; out
  Par: Variant; const Def: Variant) : Boolean;
var jsonObj: TJSONObject;
    jsonData : TJSONData;
begin
  Result := false;
  try
    jsonObj:= TJSONObject(GetJSON(H.Content));
    if assigned(jsonObj) then
    begin
      jsonData := jsonObj.Find(PS);
      if Assigned(jsonData) then
      begin
        If jsonData.JSONType = jtObject then
          Par := TJSONObject(jsonData).AsJSON else
          Par := jsonData.Value;
        if VarIsNull(Par) then Par := Def;
        Result := ((VarIsNumeric(Par) and VarIsNumeric(Def)) or
                   (VarIsStr(Par) and VarIsStr(Def)));
      end;
    end;
  finally
    if assigned(jsonObj) then FreeAndNil(jsonObj);
  end;
end;

function ParseStartLine(Request : TWCRequest; AStartLine : String) : Boolean;

Function GetNextWord(Var S : String) : string;
Var
  P : Integer;
begin
  P:=Pos(' ',S);
  If (P=0) then
    P:=Length(S)+1;
  Result:=Copy(S,1,P-1);
  Delete(S,1,P);
end;

Var
  S : String;
  I : Integer;

begin
  if aStartLine='' then
    exit(false);
  Result := True;
  Request.Method:=GetNextWord(AStartLine);
  Request.URL:=GetNextWord(AStartLine);
  S:=Request.URL;
  I:=Pos('?',S);
  if (I>0) then
    S:=Copy(S,1,I-1);
  If (Length(S)>1) and (S[1]<>'/') then
    S:='/'+S
  else if S='/' then
    S:='';
  Request.PathInfo:=S;
  S:=GetNextWord(AStartLine);
  If (S<>'') and (Pos('HTTP/',S)<>1) then
    Exit(false);
  Delete(S,1,5);
  Request.ProtocolVersion:=trim(S);
end;


Procedure InitHTTP;
begin
  Application:=TWCHTTPApplication.Create(Nil);
  if not assigned(CustomApplication) then
    CustomApplication := Application;
  //
end;

Procedure DoneHTTP;
begin
  if CustomApplication=Application then
    CustomApplication := nil;
  try
    FreeAndNil(Application);
  except
    if ShowCleanUpErrors then
      Raise;
  end;
end;

{ TWCRequest }

function TWCRequest.GetSocket: TSocketStream;
begin
  Result := Connection.Socket;
end;

function TWCRequest.GetConnection: TWCConnection;
begin
  Result := TWCConnection(Connection);
end;

procedure TWCRequest.CollectHeaders(Headers: TStringList);
var H : THeader;
begin
 For H in THeader do
   if HeaderIsSet(H) then
     Headers.Add(HTTPHeaderNames[H]+': '+GetHeader(H));
end;

{ TWebThreadSafeCacheStates }

function TWebThreadSafeCacheStates.GetStateHash(index: TWebClientState
  ): Cardinal;
begin
  Lock;
  try
    Result := FCurState[index].HashValue;
  finally
    UnLock;
  end;
end;

function TWebThreadSafeCacheStates.GetStateValue(index: TWebClientState
  ): String;
begin
  Lock;
  try
    Result := FCurState[index].SavedState;
  finally
    UnLock;
  end;
end;

procedure TWebThreadSafeCacheStates.SetStateHash(index : TWebClientState;
  AValue: Cardinal);
begin
  Lock;
  try
    FCurState[index].HashValue := AValue;
  finally
    UnLock;
  end;
end;

procedure TWebThreadSafeCacheStates.SetStateValue(index: TWebClientState;
  const AValue: String);
begin
  Lock;
  try
    FCurState[index].SavedState := AValue;
  finally
    UnLock;
  end;
end;

procedure TWebThreadSafeCacheStates.SetStatesLength(Len: integer);
begin
  SetLength(FCurState, Len);
end;

{ TWCResponse }

function TWCResponse.GetConnection: TWCConnection;
begin
  Result := TWCConnection(Connection);
end;

procedure TWCResponse.SendUTf8String(const S: String);
var L, C : integer;
begin
  L := Length(S);
  if L > 0 then
  begin
    if WCConn.HTTPVersion = wcHTTP2 then
    begin
      WCConn.HTTP2Str.Request.Response.PushData(Pointer(@(S[1])), L);
      WCConn.HTTP2Str.Request.Response.SerializeData(false);
    end else
    begin
      C := WCConn.Socket.Write(S[1], L);
      if C < 0 then
      begin
        // do nothing
        raise Exception.CreateFmt('Socket write error %d', [GetConnection.Socket.LastError]);
      end;
    end;
  end;
end;

procedure TWCResponse.CloseStream;
begin
  if WCConn.HTTPVersion = wcHTTP2 then
  begin
    WCConn.HTTP2Str.Request.Response.Close;
  end else
  begin
    // do nothing
  end;
end;

procedure TWCResponse.DoSendHeaders(Headers: TStrings);
Var
  S : String;
  I : Integer;
begin
  if Assigned(WCConn.HTTP2Str) then
  begin
    WCConn.HTTP2Str.Request.
               Response.SerializeResponseHeaders(Self,
                                                       (ContentLength = 0) and
                                                       (not FKeepAlive));
  end else
  begin
    S:=Format('HTTP/1.1 %3d %s'#13#10,[Code,GetStatusCode(Code)]);
    For I:=0 to Headers.Count-1 do
      S:=S+Headers[i]+#13#10;
    // Last line in headers is empty.
    WCConn.Socket.WriteBuffer(S[1],Length(S));
  end;
end;

procedure TWCResponse.DoSendContent;
begin
  if Assigned(WCConn.HTTP2Str) then
  begin
    WCConn.HTTP2Str.Request.Response.SerializeResponseData(Self, true); //close stream
  end else
  begin
    If Assigned(ContentStream) then
      WCConn.Socket.CopyFrom(ContentStream,0)
    else
      Contents.SaveToStream(WCConn.Socket);
  end;
end;

{ TWCConnection }

procedure TWCConnection.DoInitialize;
begin
  FInputBuf := GetMem(WC_INITIAL_READ_BUFFER_SIZE);
  FInput  := TBufferedStream.Create;
  FInput.SetPointer(FInputBuf, WC_INITIAL_READ_BUFFER_SIZE);
  FRequest := nil;
  FResponse := nil;
  FClient := nil;
  FSession := nil;
end;

function TWCConnection.ReadLine: String;
var aBuffer : AnsiString;
    OFFSET : Integer;

Procedure FillBuffer;
Var
  R : Integer;
begin
  R := 512;
  if (FInput.Size - OFFSET) < R then R := FInput.Size - OFFSET;
  SetLength(aBuffer,R);
  FInput.Read(aBuffer[1], R);
end;

Var
CheckLF,Done : Boolean;
P,L: integer;
begin
  aBuffer := '';
  Result:='';
  Done:=False;
  CheckLF:=False;
  OFFSET := FInput.Position;
  Repeat
    if Length(aBuffer)=0 then
      FillBuffer;
    if Length(aBuffer)=0 then
      Done:=True
    else if CheckLF then
    begin
      If (aBuffer[1]<>#10) then
        Result:=Result+#13
      else
      begin
        Delete(aBuffer,1,1);
        Done:=True;
      end;
      CheckLF:=False;
    end;
    if not Done then
    begin
      P:=Pos(#13#10,aBuffer);
      If P=0 then
      begin
        L:=Length(aBuffer);
        CheckLF:=aBuffer[L]=#13;
        if CheckLF then
          Result:=Result+Copy(aBuffer,1,L-1)
        else
          Result:=Result+aBuffer;
        aBuffer:='';
      end
      else
      begin
        Result:=Result+Copy(aBuffer,1,P-1);
        Delete(aBuffer,1,P+1);
        Done:=True;
      end;
    end;
  until Done;
  FInput.Position:= FInput.Position - Length(aBuffer);
end;

function TWCConnection.ReadReqHeaders: TWCRequest;
Var
  S, StartLine : String;
begin
  Result:=TWCRequest(TWCHttpServer(Server).CreateRequest);
  try
    TWCHttpServer(Server).InitRequest(Result);
    Result.SetConnection(Self);
    StartLine := ReadLine;
    ParseStartLine(Result,StartLine);
    Repeat
      S := ReadLine;
      if (S<>'') then
        ConsumeHeader(Result, S);
    Until (S='');
    Result.RemoteAddress := ESSocketAddrToString(Socket.RemoteAddress);
    Result.ServerPort := TWCHttpServer(Server).Port;
  except
    FreeAndNil(Result);
    Raise;
  end;
end;

function TWCConnection.ConvertFromHTTP2Req(AReq2: TWCHTTP2Request): TWCRequest;
begin
  if not assigned(AReq2) then Exit(nil);
  Result:=TWCRequest(TWCHttpServer(Server).CreateRequest);
  try
    TWCHttpServer(Server).InitRequest(Result);
    Result.SetConnection(Self);
    AReq2.CopyToHTTP1Request(Result);
    Result.InitRequestVars;
    Result.RemoteAddress := ESSocketAddrToString(Socket.RemoteAddress);
    Result.ServerPort := TWCHttpServer(Server).Port;
  except
    FreeAndNil(Result);
    Raise;
  end;
end;

procedure TWCConnection.ReadReqContent(ARequest: TWCRequest);
Var
  P,L,R : integer;
  S : String;
begin
  S:='';
  L:=ARequest.ContentLength;
  If (L>0) then
  begin
    SetLength(S,L);
    P:=(FInput.Size - FInput.Position);
    if (P>0) then
    begin
      FInput.Read(S[1],P);
      L:=L-P;
    end;
    P:=P+1;
    R:=1;
    While (L<>0) and (R>0) do
    begin
      R:=Socket.Read(S[p],L);
      If R<0 then
        Raise EHTTPServer.Create(WCSocketReadError);
      if (R>0) then
      begin
        P:=P+R;
        L:=L-R;
      end;
    end;
  end;
  ARequest.InitContent(S);
end;

procedure TWCConnection.ConsumeHeader(ARequest: TRequest;
  AHeader: String);
Var
  P : Integer;
  N,V : String;
begin
  V:=AHeader;
  P:=Pos(':',V);
  if (P=0) then
  begin
    UnknownHeader(ARequest,Aheader);
    Exit;
  end;
  N:=Copy(V,1,P-1);
  Delete(V,1,P);
  V:=Trim(V);
  ARequest.SetFieldByName(N,V);
end;

procedure TWCConnection.UnknownHeader(ARequest: TRequest; const AHeader: String
  );
begin
  // do nothing
end;

procedure TWCConnection.DoSocketAttach(ASocket: TSocketStream);
begin
  inherited DoSocketAttach(ASocket);
  Application.SocketsCollector.Add(SocketReference);
end;

constructor TWCConnection.Create(AServer: TAbsCustomHTTPServer;
  ASocket: TSocketStream);
begin
  inherited Create(AServer, ASocket);
  DoInitialize;
end;

constructor TWCConnection.CreateRefered(AServer: TAbsCustomHTTPServer;
  ASocketRef: TWCHTTPSocketReference);
begin
  inherited CreateRefered(AServer, ASocketRef);
  DoInitialize;
end;

function TWCConnection.ConsumeSocketData: Boolean;
var r : integer;
    aHTTP2Con : TWCHTTP2Connection;
    h2openmode : THTTP2OpenMode;
begin
  Result := true;
  try
    SetupSocket;
    r:=SocketReference.Read(FInputBuf^, WC_INITIAL_READ_BUFFER_SIZE);
    If r<0 then
      Raise EHTTPServer.Create(WCSocketReadError);
    FInput.SetPointer(FInputBuf, r);  //resize buffered stream

    try
      aHTTP2Con := TWCHttpServer(Server).HTTP2Connections.GetByHandle(Socket.Handle);
      // if HTTP2Con not nil, then reference to http2con automatically incremented
      // NOT need To increment here
      if Assigned(aHTTP2Con) then
      begin
        HTTP2Con := aHTTP2Con;
        FProtocolVersion := wcHTTP2;
        FInput.Position :=0;
      end else
      if FInput.Size > 0 then
      begin
        FProtocolVersion := TWCHTTP2Connection.CheckProtocolVersion(FInput.Memory, FInput.Size);
        if FProtocolVersion = wcHTTP2 then begin
           h2openmode := h2oPrefaceMode;
           FInput.Position:= H2P_PREFACE_SIZE;
        end else begin
           FInput.Position:= 0;
        end;
        if FProtocolVersion = wcHTTP1 then
        begin
          // Read headers.
          FRequest:= ReadReqHeaders;
          // Read content, if any
          If FRequest.ContentLength>0 then
            ReadReqContent(FRequest);
          FRequest.InitRequestVars;
          //check here if http1.1 upgrade to http2
          //  !!
          //    !!
          //      !!
          if FProtocolVersion = wcHTTP1 then
          begin
            // Create Response
            FResponse:= TWCResponse(TWCHttpServer(Server).CreateResponse(FRequest));
            TWCHttpServer(Server).InitResponse(FResponse);
            FResponse.SetConnection(Self);
          end;
        end;
      end else Result := false;
      if FProtocolVersion = wcHTTP2 then
      begin
        // read http/2 frames
        // RFC 7540
        // find stream, consume data
        Result := True;
        if not Assigned(HTTP2Con) then
        begin
          HTTP2Con := TWCHttpServer(Server).AttachNewHTTP2Con(SocketReference,
                                                              h2openmode,
                                                              @(TWCHttpServer(Server).DoConnectToSocketRef));
          HTTP2Con.IncReference; // reference not incremented here, need to increment
        end;
        if FInput.Size > 0 then
           HTTP2Con.ConsumeNextFrame(FInput);
        HTTP2Str := HTTP2Con.PopRequestedStream;
        if Assigned(HTTP2Str) then
        begin
          FRequest := ConvertFromHTTP2Req(HTTP2Str.Request);
          FResponse:= TWCResponse(TWCHttpServer(Server).CreateResponse(FRequest));
          TWCHttpServer(Server).InitResponse(FResponse);
          FResponse.SetConnection(Self);
        end else Result := false;
      end;
    finally
      //
    end;
  Except
    On E : Exception do begin
      Result := false;
      if Assigned(FRequest) then FreeAndNil(FRequest);
      if Assigned(FResponse) then FreeAndNil(FResponse);
      HandleRequestError(E);
    end;
  end;
end;

procedure TWCConnection.SetSessionParams(aClient: TWebClient;
  aSession: TSqliteWebSession);
begin
  FClient := aClient;
  FClient.IncReference;
  FSession := aSession;
end;

destructor TWCConnection.Destroy;
begin
  if Assigned(FRequest) then FreeAndNil(FRequest);
  if Assigned(FResponse) then FreeAndNil(FResponse);
  if Assigned(FSession) then FreeAndNil(FSession);
  if Assigned(FClient) then FClient.DecReference;
  FInput.Free;
  FreeMem(FInputBuf);
  inherited Destroy;
end;

{ TWCPreAnalizeClientJob }

function TWCPreAnalizeClientJob.GetRequest: TWCRequest;
begin
  Result := Connection.Request;
end;

function TWCPreAnalizeClientJob.GetResponse: TWCResponse;
begin
  Result := Connection.Response;
end;

constructor TWCPreAnalizeClientJob.Create(aConn: TWCConnection);
begin
  FConn := aConn;
end;

destructor TWCPreAnalizeClientJob.Destroy;
begin
  if assigned(FConn) then begin
    FConn.Free;
  end;
  inherited Destroy;
end;

procedure TWCPreAnalizeClientJob.Execute;
var ASynThread : TWCMainClientJob;
    aClient : TWebClient;
    aSession : TSqliteWebSession;
begin
 try
  if Assigned(FConn) and FConn.ConsumeSocketData and
     TWCHttpServer(FConn.Server).ServerActive then begin

    WebContainer.Clients.Lock;
    try
      aSession := WebContainer.CreateSession(Request);
      if Assigned(aSession) then
      begin
        aSession.InitSession(Request, @(WebContainer.OnCreateNewSession), nil);
        if ssNew in aSession.SessionState then
          aSession.InitResponse(Response); // fill cookies
        if ssExpired in aSession.SessionState then
        begin
          Application.SendError(Response, 205);
          Exit;
        end else
        begin
          //try to find client
          //or
          //if new session then try to create client in clients pool
          //using ARequest to deteminate some additional data
          aClient := WebContainer.AddClient(Request, aSession.SessionID);
          if not assigned(aClient) then begin
            Application.SendError(Response, 405);
            Exit;
          end else begin
            aClient.Initialize;
          end;
        end;
      end;
      FConn.SetSessionParams(aClient, aSession);
    finally
      WebContainer.Clients.UnLock;
    end;
    //
    ASynThread := GenerateClientJob;
    if Assigned(ASynThread) then
    begin
      FConn := nil; //now fconn is part of ASynThread job
      Application.ESServer.AddToMainPool(ASynThread);
    end;
    //
  end;
 except
   //
 end;
end;

function TWCPreAnalizeClientJob.GenerateClientJob: TWCMainClientJob;
begin
  Result := nil;
end;

{ TWCMainClientJob }

function TWCMainClientJob.GetClient: TWebClient;
begin
  Result := Connection.Client;
end;

function TWCMainClientJob.GetRequest: TWCRequest;
begin
  Result := Connection.Request;
end;

function TWCMainClientJob.GetResponse: TWCResponse;
begin
  Result := Connection.Response;
end;

constructor TWCMainClientJob.Create(aConn: TWCConnection);
begin
  inherited Create(aConn.Client.Score);
  aConn.Client.UpdateScore;
  FConn := aConn;
  FResponseReadyToSend := true;
end;

destructor TWCMainClientJob.Destroy;
begin
  if Assigned(FConn) then begin
    FConn.Free;
    FConn := nil;
  end;
  inherited Destroy;
end;

procedure TWCMainClientJob.Execute;
begin
  // do something in ancestor's class
  if ResponseReadyToSend then
    Connection.Response.SendContent;
end;

procedure TWCMainClientJob.ReleaseConnection;
begin
  FConn := nil; // clear reference to connection
end;

{ TWCHttpServer }

procedure TWCHttpServer.SetMaxMainClientsThreads(AValue: Byte);
begin
  if FMaxMainClientsThreads=AValue then Exit;
  FMaxMainClientsThreads:=AValue;
end;

procedure TWCHttpServer.SetMaxPreClientsThreads(AValue: Byte);
begin
  if FMaxPreClientsThreads=AValue then Exit;
  FMaxPreClientsThreads:=AValue;
end;

function TWCHttpServer.CompareMainJobs(Tree: TAvgLvlTree; Data1, Data2: Pointer
  ): Integer;
begin
  Result := CompareValue(TWCMainClientJob(Data1).Score,
                         TWCMainClientJob(Data2).Score);
end;

constructor TWCHttpServer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPoolsLocker := TNetCustomLockedObject.Create;
  FHTTP2Connections := TWCHTTP2Connections.Create;
  FMaxMainClientsThreads := 1;
  FMaxPreClientsThreads  := 1;
end;

function TWCHttpServer.CreateSSLSocketHandler: TSocketHandler;
begin
  Result:=inherited CreateSSLSocketHandler;
  if assigned(Result) then
  begin
    TExtOpenSSLSocketHandler(Result).AlpnList := AlpnList;
    TExtOpenSSLSocketHandler(Result).SSLMasterKeyLog:= SSLMasterKeyLog;
  end;
end;

procedure TWCHttpServer.CreateConnectionThread(Conn: TAbsHTTPConnection);
var PreJob : TWCPreAnalizeClientJob;
begin
  if assigned(Application.ServerAnalizeJobClass) then
     PreJob := Application.ServerAnalizeJobClass.Create(TWCConnection(Conn))
  else
     PreJob := TWCPreAnalizeClientJob.Create(TWCConnection(Conn));

  FPoolsLocker.Lock;
  try
    if not assigned(FPreThreadPool) then
    begin
       FPreThreadPool := TThreadPool.Create(FMaxPreClientsThreads);
       FPreThreadPool.Running := true;
    end;
  finally
    FPoolsLocker.UnLock;
  end;

  FPreThreadPool.Add(PreJob);
end;

function TWCHttpServer.CreateConnection(Data: TSocketStream): TAbsHTTPConnection;
begin
  Result:= TWCConnection.Create(Self, Data);
end;

function TWCHttpServer.CreateRequest: TAbsHTTPConnectionRequest;
begin
  Result:=TWCRequest.Create;
end;

function TWCHttpServer.CreateResponse(ARequest: TAbsHTTPConnectionRequest
  ): TAbsHTTPConnectionResponse;
begin
  Result:=TWCResponse.Create(ARequest);
  TWCResponse(Result).KeepStreamAlive:=false;
end;

procedure TWCHttpServer.InitRequest(ARequest: TAbsHTTPConnectionRequest);
begin
  inherited InitRequest(ARequest);
end;

procedure TWCHttpServer.InitResponse(AResponse: TAbsHTTPConnectionResponse);
begin
  inherited InitResponse(AResponse);
end;

function TWCHttpServer.AttachNewHTTP2Con(aSocket: TWCHTTPSocketReference;
  aOpenMode: THTTP2OpenMode; aServerDoConsume: THttp2SocketConsume
  ): TWCHTTP2Connection;
begin
  Result := TWCHTTP2Connection.Create(Application.GarbageCollector,
                                      aSocket,
                                      aOpenMode,
                                      aServerDoConsume);
  Application.GarbageCollector.Add(Result);
  FHTTP2Connections.Push_back(Result);
end;

procedure TWCHttpServer.AddToMainPool(AJob: TWCMainClientJob);
begin
  FPoolsLocker.Lock;
  try
    if not Assigned(FMainThreadPool) then
    begin
      FMainThreadPool := TSortedThreadPool.Create(@CompareMainJobs,
                                                  FMaxMainClientsThreads);
      FMainThreadPool.Running := true;
    end;
  finally
    FPoolsLocker.UnLock;
  end;

  FMainThreadPool.Add(AJob);
end;

function TWCHttpServer.ServerActive: Boolean;
begin
  Result := Active;
end;

procedure TWCHttpServer.DoConnectToSocketRef(SockRef: TWCHTTPSocketReference);
Var
  Con : TWCConnection;
begin
  SockRef.Lock;
  try
    Con:=TWCConnection.CreateRefered(Self, SockRef);
  finally
    SockRef.UnLock;
  end;
  Con.OnRequestError:=@HandleRequestError;
  CreateConnectionThread(Con);
end;

destructor TWCHttpServer.Destroy;
begin
  if Assigned(FMainThreadPool) then FMainThreadPool.Free;
  if Assigned(FPreThreadPool) then FPreThreadPool.Free;
  FPoolsLocker.Free;
  FHTTP2Connections.Free;
  inherited Destroy;
end;

{ TWCHttpServerHandler }

function TWCHttpServerHandler.CreateServer: TEmbeddedAbsHttpServer;
begin
  Result:=TWCHttpServer.Create(Self);
end;

function TWCHttpServerHandler.GetESServer: TWCHttpServer;
begin
  Result := TWCHttpServer(HTTPServer);
end;

{ TWebClient }

function TWebClient.GetAcceptGZip: Boolean;
begin
  Result := FAcceptGZip.Value;
end;

function TWebClient.GetLastConnection: Integer;
begin
  Result := FLastConnection.Value;
end;

function TWebClient.GetScore: Integer;
begin
  Result := FScore.Value;
end;

function TWebClient.GetStateHash(index : TWebClientState): Cardinal;
begin
  Result := FCurStates.Hash[index];
end;

function TWebClient.GetAcceptDeflate: Boolean;
begin
  Result := FAcceptDeflate.Value;
end;

function TWebClient.GetHasSynConnection: Boolean;
begin
  Result := FHasSynConnection.Value;
end;

procedure TWebClient.SetAcceptDeflate(AValue: Boolean);
begin
  FAcceptDeflate.Value:= AValue;
end;

procedure TWebClient.SetAcceptGZip(AValue: Boolean);
begin
  FAcceptGZip.Value := AValue;
end;

procedure TWebClient.SetHasSynConnection(AValue: Boolean);
begin
  FHasSynConnection.Value:= AValue;
end;

procedure TWebClient.SetScore(AValue: Integer);
begin
  FScore.Value := AValue;
end;

function TWebClient.GenerateNewStateHash: Cardinal;
var cT : Qword;
begin
  cT := GetTickCount64;
  Result := Cardinal(cT - FStartStamp);
end;

constructor TWebClient.Create(AOwner: TWebClients; const aCUID: String);
begin
  inherited Create;
  FCUID := aCUID;
  FOwner := AOwner;
  FStartStamp := GetTickCount64;
  FCurStates := TWebThreadSafeCacheStates.Create;
  FHasSynConnection := TThreadBoolean.Create(false);
  FAcceptGZip := TThreadBoolean.Create(false);
  FAcceptDeflate := TThreadBoolean.Create(false);
  FOnRemove:=nil;
  FScore := TThreadInteger.Create(0);
  FLastConnection := TThreadInteger.Create(0);
  FOwner.AddNew(aCUID, Self);

  Application.GarbageCollector.Add(Self);
end;

destructor TWebClient.Destroy;
begin
  if assigned(FOnRemove) then
     FOnRemove(Self);
  FOwner.RemoveClientNotDestroy(FCUID);

  FAcceptGZip.Free;
  FAcceptDeflate.Free;
  FHasSynConnection.Free;

  FLastConnection.Free;
  FScore.Free;

  FCurStates.Free;

  inherited Destroy;
end;

procedure TWebClient.DoIdle;
begin
  RelaxScore;
end;

procedure TWebClient.UpdateScore;
var CTS : Cardinal;
begin
  CTS := Application.GetTimeSecFromStart;
  if (CTS - FLastConnection.Value) < 10 then FScore.IncValue;
  FLastConnection.Value := CTS;
end;

procedure TWebClient.RelaxScore;
var CTS : Cardinal;
begin
  CTS := Application.GetTimeSecFromStart;
  if (FScore.Value > 0) and ((CTS - FLastConnection.Value) > 10) then
     FScore.DecValue;
end;

procedure TWebClient.Initialize;
begin
  //override this
end;

function TWebClient.SaveNewState(aState: TWebClientState;
  const aNewState: String; oldHash: Cardinal;
  ignoreHash : boolean = false): Boolean;
begin
  if ignoreHash or
     (oldHash = 0) or
     (oldHash <> FCurStates.Hash[aState]) or
     (not SameStr(FCurStates.Value[aState], aNewState)) then
  begin
    FCurStates.Value[aState] := aNewState;
    FCurStates.Hash[aState]  := GenerateNewStateHash;
    Result := True;
  end else
    Result := False;
end;

procedure TWebClient.ResponseString(AResponse: TResponse; const S: String);
var
  deflateStream : TDefcompressionstream;
  L : Longint;
  NeedCompress : Boolean;
  {$IFDEF ALLOW_STREAM_GZIP}
  gzStream : TGzCompressionstream;
  {$ENDIF}
begin
  L := Length(S);
  NeedCompress:= L > Application.CompressLimit;
  {$IFDEF ALLOW_STREAM_GZIP}
  if AcceptGzip and NeedCompress then
  begin
    AResponse.ContentStream := TMemoryStream.Create;
    gzStream := Tgzcompressionstream.create(cldefault, AResponse.ContentStream);
    try
      gzStream.WriteBuffer(S[1], L);
    finally
      gzStream.Free;
    end;
    AResponse.FreeContentStream:=true;
    AResponse.ContentStream.Position:=0;
    AResponse.ContentLength := AResponse.ContentStream.Size;
    AResponse.SetHeader(hhContentEncoding, cSgzip);
  end else
  {$ENDIF}
  if AcceptDeflate and NeedCompress then
  begin
    AResponse.ContentStream := TMemoryStream.Create;
    deflateStream := Tdefcompressionstream.create(cldefault, AResponse.ContentStream);
    try
      deflateStream.WriteBuffer(S[1], L);
    finally
      deflateStream.Free;
    end;
    AResponse.FreeContentStream:=true;
    AResponse.ContentStream.Position:=0;
    AResponse.ContentLength := AResponse.ContentStream.Size;
    AResponse.SetHeader(hhContentEncoding, cSdeflate);
  end else
    AResponse.Content:=S;
end;

{ TWebClients }

function TWebClients.GetClient(const cUID: String): TWebClient;
begin
  Lock;
  try
    Result := TWebClient(FHash[cUID]);
  finally
    UnLock;
  end;
end;

function TWebClients.IsClientDead(aClient: TObject; data: pointer): Boolean;
begin
  // TWebClients already locked here
  Result := not Container.Sessions.IsActiveSession(TWebClient(aClient).FCUID);
  if Result then
    Application.DoInfo('Client is dead ' + TWebClient(aClient).CUID);
end;

procedure TWebClients.AfterClientExtracted(aObj: TObject);
begin
  TWebClient(aObj).DecReference;
end;

procedure TWebClients.IdleClient(aObj: TObject);
var aClient : TWebClient;
begin
  aClient := TWebClient(aObj);
  aClient.DoIdle;
end;

constructor TWebClients.Create(aContainer: TWebClientsContainer);
begin
  inherited Create;
  FContainer := aContainer;
  FHash := TStringHashList.Create(true);
end;

destructor TWebClients.Destroy;
begin
  FHash.Free;
  inherited Destroy;
end;

procedure TWebClients.Clear;
begin
  Lock;
  try
    Clean;
  finally
    Unlock;
  end;
end;

procedure TWebClients.AddNew(const cUID: String; aClient: TWebClient);
begin
  Lock;
  try
    FHash.Add(cUID, aClient);
    Push_back(aClient);
  finally
    UnLock;
  end;
end;

procedure TWebClients.RemoveClient(aClient: TWebClient);
begin
  Lock;
  try
    ExtractObject(aClient);
    aClient.DecReference;
  finally
    UnLock;
  end;
end;

procedure TWebClients.RemoveClient(const cUID: String);
var aClient : TWebClient;
begin
  Lock;
  try
    aClient := Client[cUID];
    RemoveClient(aClient);
  finally
    UnLock;
  end;
end;

procedure TWebClients.RemoveClientNotDestroy(const cUID: String);
begin
  Lock;
  try
    FHash.Remove(cUID);
  finally
    UnLock;
  end;
end;

procedure TWebClients.ClearDeadClients;
begin
  ExtractObjectsByCriteria(@IsClientDead, @AfterClientExtracted, nil);
end;

procedure TWebClients.IdleLiveClients;
begin
  DoForAll(@IdleClient)
end;

{ TWebCacheCollection }

function TWebCacheCollection.GetCache(const index: String): TWebCachedItem;
begin
  Result := TWebCachedItem(FHash[index]);
end;

constructor TWebCacheCollection.Create;
begin
  inherited Create;
  FHash := TStringHashList.Create(true);
end;

destructor TWebCacheCollection.Destroy;
begin
  FHash.Free;
  inherited Destroy;
end;

procedure TWebCacheCollection.Clear;
begin
  Lock;
  try
    FHash.Clear;
  finally
    Unlock;
  end;
  inherited Clear;
end;

procedure TWebCacheCollection.AddNew(const aName: String; aData: TWebCachedItem
  );
begin
  Lock;
  try
    FHash.Add(aName, aData);
  finally
    UnLock;
  end;
  Add(aData);
end;

{ TWCHTTPApplication }

procedure TWCHTTPApplication.DoOnException(Sender: TObject; E: Exception);
begin
  DoError(E.Message);
end;

procedure TWCHTTPApplication.DoGetModule(Sender: TObject; ARequest: TRequest;
  var ModuleClass: TCustomHTTPModuleClass);
begin
  ModuleClass := nil;
end;

constructor TWCHTTPApplication.Create(AOwner: TComponent);
var I : integer;
begin
  inherited Create(AOwner);

  FNetDebugMode:=False;

  {$ifdef NOGUI}{$IFDEF UNIX}
  GWidgetHelper := TGWidgetSetHelper.Create;
  {$endif}{$ENDIF}

  OnGetModule:= @DoGetModule;
  //
  FMTime := GetTickCount64;

  if not TryStrToInt(ParamStr(1), i) then
  begin
    raise Exception.CreateFmt('Wrong port number "%s"', [ParamStr(1)]);
  end else
    Port := I;

  for I := 2 to ParamCount do
  begin
    if SameText(ParamStr(i), '-debug') or SameText(ParamStr(i), 'debug') then
       FNetDebugMode:=true;
  end;
end;

destructor TWCHTTPApplication.Destroy;
begin
  DoInfo('Server stopped');
  {$ifdef NOGUI}{$IFDEF UNIX}
  GWidgetHelper.Free;
  {$endif}{$endif}
  if assigned(WebContainer) then FreeAndNil(WebContainer);
  if assigned(FReferences) then FreeAndNil(FReferences);
  if assigned(FSocketsReferences) then FreeAndNil(FSocketsReferences);
  //
  FLogDB.Free;
  inherited Destroy;
end;

procedure TWCHTTPApplication.DoOnIdle(sender: TObject);
var T : QWord;
begin
  {$ifdef NOGUI} {$IFDEF UNIX}
  GWidgetHelper.ProcessMessages;
  {$endif}  {$endif}
  T := GetTickCount64;
  if (T - FMTime) >= 10000 then  //every 10 secs
  begin
    FMTime := T;
    WebContainer.DoMaintainingStep;
    GarbageCollector.CleanDead;
  end;
  //
  ESServer.HTTP2Connections.Idle;
  //
  FSocketsReferences.CleanDead;
  Sleep(10);
end;

function TWCHTTPApplication.GetESServer: TWCHttpServer;
begin
  Result := GetWebHandler.GetESServer;
end;

procedure TWCHTTPApplication.SetMaxMainThreads(AValue: Byte);
begin
  if AValue = 0 then AValue := 1;
  if AValue > WC_MAX_MAIN_THREADS then AValue := WC_MAX_MAIN_THREADS;
  if FMaxMainThreads=AValue then Exit;
  FMaxMainThreads:=AValue;
  if assigned(GetESServer) then
     GetESServer.MaxMainClientsThreads:=aValue;
end;

procedure TWCHTTPApplication.SetMaxPrepareThreads(AValue: Byte);
begin
  if AValue = 0 then AValue := 1;
  if AValue > WC_MAX_PREP_THREADS then AValue := WC_MAX_PREP_THREADS;
  if FMaxPrepareThreads=AValue then Exit;
  FMaxPrepareThreads:=AValue;       
  if assigned(GetESServer) then
     GetESServer.MaxPreClientsThreads:=aValue;
end;

procedure TWCHTTPApplication.SetSSLLoc(AValue: String);
begin
  FSSLLoc := AVAlue;
  if assigned(ESServer) then
    ESServer.SSLLoc := ExtractFilePath(ExeName) + AValue;
end;

procedure TWCHTTPApplication.DoInfo(const V: String);
begin
  FLogDB.LogAdd(LOG_INFO, V);
end;

procedure TWCHTTPApplication.DoInfo(const V: String;
  const aParams: array of const);
begin
  FLogDB.LogAdd(LOG_INFO, V, aParams);
end;

procedure TWCHTTPApplication.DoError(const V: String);
begin
  FLogDB.LogAdd(LOG_ERROR, V);
end;

procedure TWCHTTPApplication.DoError(const V: String;
  const aParams: array of const);
begin
  FLogDB.LogAdd(LOG_ERROR, V, aParams);
end;

procedure TWCHTTPApplication.SendError(AResponse: TResponse; errno: Integer);
begin
  AResponse.Code:=errno;
  AResponse.Content:='';
  if not AResponse.HeadersSent then
    AResponse.SendHeaders;
end;

procedure TWCHTTPApplication.Initialize;
begin
  vPath := UnicodeString(ExtractFilePath(ExeName) + WebFilesLoc);
  FLogDB := TSqliteLogger.Create(ExtractFilePath(ExeName) + LogDb);
  OnException:=@DoOnException;
  DoInfo('Server started');

  inherited Initialize;

  MimeTypesFile := UTF8Encode(vPath + UnicodeString(MimeLoc));
  MimeTypes.LoadFromFile(MimeTypesFile);

  if assigned(ESServer) then
     ESServer.SSLLoc:= UTF8Encode(vPath + UnicodeString(FSSLLoc));;

  FReferences := TNetReferenceList.Create;
  FSocketsReferences :=TNetReferenceList.Create;
  WebContainer := TWebClientsContainer.Create;
  GetWebHandler.OnAcceptIdle:= @DoOnIdle;
  GetWebHandler.AcceptIdleTimeout:=1;

  GetESServer.MaxMainClientsThreads := MaxMainThreads;
  GetESServer.MaxPreClientsThreads  := MaxPrepareThreads;

  FStartStamp:= GetTickCount64;
  DoInfo('Server initialized');
end;

function TWCHTTPApplication.GetWebHandler: TWCHttpServerHandler;
begin
  Result := TWCHttpServerHandler(WebHandler);
end;

function TWCHTTPApplication.InitializeAbstractWebHandler: TWebHandler;
begin
  Result:=TWCHttpServerHandler.Create(Self);
end;

function TWCHTTPApplication.GetTimeSecFromStart: Cardinal;
begin
  Result := (GetTickCount64 - FStartStamp) div 1000;
end;

{ TWebCachedItem }

function TWebCachedItem.GetCache: TMemoryStream;
begin
  FCache.Position:=0;
  Result := FCache;
end;

function TWebCachedItem.GetDeflateCache: TMemoryStream;
begin
  FDeflateCache.Position:=0;
  Result := FDeflateCache;
end;

function TWebCachedItem.GetDeflateReady: Boolean;
begin
  Lock;
  try
    Result := Assigned(FDeflateCache);
  finally
    UnLock;
  end;
end;

function TWebCachedItem.GetDeflateSize: QWord;
begin
  Lock;
  try
    Result := FDeflateSize;
  finally
    UnLock;
  end;
end;

{$IFDEF ALLOW_STREAM_GZIP}
function TWebCachedItem.GetGzipCache: TMemoryStream;
begin
  FGzipCache.Position:=0;
  Result := FGzipCache;
end;

function TWebCachedItem.GetGzipReady: Boolean;
begin
  Lock;
  try
    Result := Assigned(FGzipCache);
  finally
    UnLock;
  end;
end;

function TWebCachedItem.GetGzipSize: QWord;
begin
  Lock;
  try
    Result := FGzipSize;
  finally
    UnLock;
  end;
end;
{$ENDIF}

function TWebCachedItem.GetMimeType: String;
begin
  Lock;
  try
    Result := FMimeType;
  finally
    UnLock;
  end;
end;

function TWebCachedItem.GetSize: QWord;
begin
  Lock;
  try
    Result := FSize;
  finally
    UnLock;
  end;
end;

constructor TWebCachedItem.Create(const aLoc: String);
begin
  inherited Create;
  FCache := TMemoryStream.Create;
  FLoc := aLoc;
  FSize := 0;
  {$IFDEF ALLOW_STREAM_GZIP}
  FGzipCache := nil;
  FGzipSize:= 0;
  {$ENDIF}
  FDeflateSize:= 0;
  FDataTime := EncodeDate(1990, 1, 1);
  FMimeType := MimeTypes.GetMimeType(ExtractFileExt(aLoc));
  If Length(FMimeType) = 0 then
    FMimeType:='Application/octet-stream';

  FDeflateCache := nil;

  if (Pos('image/',    FMimeType) = 1) or
     (((Pos('text/html', FMimeType) = 1) or
       (Pos('text/css',  FMimeType) = 1) or
       (Pos('application/javascript',  FMimeType) = 1)) and
                            Application.NetDebugMode) then begin
    // for all pictures allow cache 1 hr
    FCacheControl := 'public, max-age=3600';
  end else
    FCacheControl := 'no-cache';

  FNeedToCompress := (Pos('text/', FMimeType) = 1) or
                     (Pos('application/', FMimeType) = 1);
end;

destructor TWebCachedItem.Destroy;
begin
  FCache.Free;
  if assigned(FDeflateCache) then FDeflateCache.Free;
  {$IFDEF ALLOW_STREAM_GZIP}
  if assigned(FGzipCache) then FGzipCache.Free;
  {$ENDIF}
  inherited Destroy;
end;

procedure TWebCachedItem.Clear;
begin
  FCache.Clear;
  FCache.Position:= 0;
  FSize := 0;
end;

procedure TWebCachedItem.Refresh;
var F : TFileStream;
  cDT : TDateTime;
  deflateStream : TDefcompressionstream;
  {$IFDEF ALLOW_STREAM_GZIP}
  gzStream : Tgzcompressionstream;
  {$ENDIF}
begin
  Lock;
  try
    if FileExists(FLoc) then
    begin
      FileAge(FLoc, cDT);
      if SecondsBetween(cDT, FDataTime) > 0 then
      begin
        FDataTime := cDT;
        F:=TFileStream.Create(FLoc, fmOpenRead or fmShareDenyWrite);
        try
          FSize:=F.Size;
          FCache.SetSize(FSize);
          FCache.Position := 0;
          FCache.CopyFrom(F, FSize);
        finally
          F.Free;
        end;
        if Assigned(FDeflateCache) then FreeAndNil(FDeflateCache);
        {$IFDEF ALLOW_STREAM_GZIP}
        if assigned(FGzipCache) then FreeAndNil(FGzipCache);
        {$ENDIF}
        if FNeedToCompress then
        begin
          FDeflateCache := TMemoryStream.Create;
          deflateStream := TDefcompressionstream.create(cldefault, FDeflateCache);
          try
            FCache.Position:=0;
            deflateStream.CopyFrom(FCache, FSize);
          finally
            deflateStream.Free;
          end;
          FDeflateSize := FDeflateCache.Size;
          if FDeflateSize = 0 then
              FreeAndNil(FDeflateCache);

          {$IFDEF ALLOW_STREAM_GZIP}
          FGzipCache := TMemoryStream.Create;
          gzStream := Tgzcompressionstream.create(cldefault, FGzipCache);
          try
            FCache.Position:=0;
            gzStream.CopyFrom(FCache, FSize);
          finally
            gzStream.Free;
          end;
          FGzipSize := FGzipCache.Size;
          if FGzipSize = 0 then
             FreeAndNil(FGzipCache);
          {$ENDIF}
        end;
      end;
    end else Clear;
  finally
    UnLock;
  end;
end;

{ TWebClientsContainer }

procedure TWebClientsContainer.ClientRemove(Sender: TObject);
var aClient : TWebClient;
begin
  aClient := TWebClient(Sender);

  PREP_ClientStop.Execute([aClient.CUID]);
  Application.DoInfo('Client removed ' + aClient.CUID);
end;

function TWebClientsContainer.OnGenSessionID(aSession: TSqliteWebSession
  ): String;
var CID : Cardinal;
begin
  CID := FCurCID.ID;
  Result := EncodeIntToSID(CID, 4) + '-' +
            EncodeInt64ToSID(QWord(TimeStampToMSecs(DateTimeToTimeStamp(Now))), 8);
  PREP_ClientSetLastCUID.Execute([CID+1]);
end;

constructor TWebClientsContainer.Create;
begin
  inherited Create;

  FCachedPages := TWebCacheCollection.Create;
  FConnectedClients := TWebClients.Create(Self);

  GetWebCachedItem(UTF8Encode(vPath) + Application.MainURI);

  FClientsDB := TExtSqlite3Dataset.Create(nil);
  FClientsDB.FileName := UTF8Encode(vPath) +
                      Application.SessionsLoc + cSysDelimiter +
                      Application.SessionsDb;

  FCurCID := TThreadSafeAutoIncrementCardinal.Create;

  FSessions := TSqliteSessionFactory(SessionFactory);
  FSessions.DefaultTimeOutMinutes:=10;
  FSessions.InitializeDB(FClientsDB);
  FSessions.SessionCookiePath:='/; SameSite=Strict; Max-Age=86400';
  FSessions.CleanupInterval:=0; // manual cleanup
  FSessions.OnGenSessionID:= @OnGenSessionID;

  FClientsDB.ExecSQL(
  'create table if not exists clientsbase'+
    '(id integer primary key autoincrement, '+
     'start timestamp default current_timestamp,'+
     'stop timestamp default current_timestamp,'+
     'CUID text,'+
     'IPv4 text,'+
     'IPv6 text,'+
     'httpAccept text,'+
     'httpAcceptCharset text,'+
     'httpAcceptEncoding text,'+
     'httpAcceptLanguage text,'+
     'httpUserAgent text);');

  FClientsDB.ExecSQL(
  'create table if not exists clientcuid'+
  '(id integer default 1);');

  FClientsDB.ExecSQL(
  'create table if not exists netsessions'+
  '(id integer primary key autoincrement, '+
   'start timestamp default current_timestamp,'+
   'request_comm text,'+
   'request_socket int,'+
   'request_header text,'+
   'request_cookies text,'+
   'request_query text,'+
   'request_content text);');

  FClientsDB.ExecSQL('INSERT INTO clientcuid (id) '+
                                  'SELECT 1 WHERE NOT EXISTS (SELECT * FROM clientcuid)');

  PREP_AddClientToBase := FClientsDB.AddNewPrep(
   'INSERT INTO clientsbase '+
   '(CUID,IPv4,IPv6,'+
    'httpAccept,'+
    'httpAcceptCharset,'+
    'httpAcceptEncoding,'+
    'httpAcceptLanguage,'+
    'httpUserAgent) values(?1,?2,?3,?4,?5,?6,?7,?8);');

  PREP_ClientStop := FClientsDB.AddNewPrep(
    'update clientsbase set stop = current_timestamp where CUID = ?1;');

  PREP_ClientSetLastCUID := FClientsDB.AddNewPrep(
    'update clientcuid set id = ?1;');

  PREP_ClientGetLastCUID := FClientsDB.AddNewPrep(
    'select id from clientcuid;');

  PREP_OnCreateSession := FClientsDB.AddNewPrep(
   'INSERT INTO netsessions '+
   '(request_comm,request_socket,request_header,request_cookies,request_query,request_content) values(?1,?2,?3,?4,?5,?6);');

  PREP_DeleteOldNetRequests := FClientsDB.AddNewPrep(
   'delete from netsessions '+
   'where (julianday(current_timestamp)-julianday(start)) > 1.0;');

  FCurCID.SetValue(StrToInt(PREP_ClientGetLastCUID.QuickQuery([], nil, false)));
  PREP_DeleteOldNetRequests.Execute([]);
end;

destructor TWebClientsContainer.Destroy;
begin
  FCachedPages.Free;
  FConnectedClients.Free;
  FClientsDB.Free;
  FCurCID.Free;
  inherited Destroy;
end;

procedure TWebClientsContainer.ClearCache;
begin
  FCachedPages.Clear;
end;

function TWebClientsContainer.CreateSession(ARequest: TWCRequest
  ): TSqliteWebSession;
var reqHeaders  : TStringList;
begin
  Result := TSqliteWebSession(Sessions.CreateSession(ARequest));

  if Application.NetDebugMode then
  begin
    reqHeaders := TStringList.Create;
    try
      ARequest.CollectHeaders(reqHeaders);
      PREP_OnCreateSession.Execute([ARequest.HeaderLine,
                                    ARequest.Socket.Handle,
                                    Trim(reqHeaders.Text),
                                    Trim(ARequest.CookieFields.Text),
                                    Trim(ARequest.Method),
                                    Trim(ARequest.Content)]);
    finally
      reqHeaders.Free;
    end;
  end;
end;

Function ESSocketAddrToString(ASocketAddr: TSockAddr): String;
begin
  if ASocketAddr.sa_family = AF_INET then
    Result := NetAddrToStr(ASocketAddr.sin_addr)
  else // no ipv6 support yet
    Result := '';
end;

function ESGetLocalAddress(Handle : Cardinal): sockets.TSockAddr;
var
  len: LongInt;
begin
  len := SizeOf(sockets.TSockAddr);
  if fpGetSockName(Handle, @Result, @len) <> 0 then
    FillChar(Result, SizeOf(Result), 0);
end;

function ESGetGetRemoteAddress(Handle : Cardinal): sockets.TSockAddr;
var
  len: LongInt;
begin
  len := SizeOf(sockets.TSockAddr);
  if fpGetPeerName(Handle, @Result, @len) <> 0 then
    FillChar(Result, SizeOf(Result), 0);
end;

procedure TWebClientsContainer.OnCreateNewSession(Sender: TObject);
var ARequest : TWCRequest;
  Session : TSqliteWebSession;
  Con : TWCConnection;
  IpV4, IpV6 : String;
  SocketAddr : TSockAddr;
begin
  Session := TSqliteWebSession(Sender);
  try
    ARequest := TWCRequest(Session.Request);
    Con := ARequest.GetConnection;

    SocketAddr := ESGetGetRemoteAddress(Con.Socket.Handle);

    IpV4 := ESSocketAddrToString(SocketAddr);
    IpV6 := '';
    PREP_AddClientToBase.Execute([Session.SID,
                                  IpV4,
                                  IpV6,
                                  ARequest.GetHeader(hhAccept),
                                  ARequest.GetHeader(hhAcceptCharset),
                                  ARequest.GetHeader(hhAcceptEncoding),
                                  ARequest.GetHeader(hhAcceptLanguage),
                                  ARequest.GetHeader(hhUserAgent)]);
  finally
  end;
end;

function TWebClientsContainer.AddClient(ARequest: TRequest;
  const ClientID: String): TWebClient;
begin
  Result := FConnectedClients.GetClient(ClientID);
  if not assigned(Result) then
  begin
    Result := Application.WebClientClass.Create(FConnectedClients, ClientID);
    Result.OnRemove:= @ClientRemove;
    Result.AcceptGzip:=  Pos(cSgzip, ARequest.GetHeader(hhAcceptEncoding)) > 0;
    Result.AcceptDeflate:=Pos(cSdeflate, ARequest.GetHeader(hhAcceptEncoding)) > 0;
    Application.DoInfo('Client added ' + ClientID);
  end;
end;

function TWebClientsContainer.GetClient(const ClientID: String): TWebClient;
begin
  Result := FConnectedClients.GetClient(ClientID);
end;

procedure TWebClientsContainer.RemoveClient(const ClientID: String);
begin
  FConnectedClients.RemoveClient(ClientID);
end;

procedure TWebClientsContainer.RemoveClient(mClient: TWebClient);
begin
  FConnectedClients.RemoveClient(mClient);
end;

procedure TWebClientsContainer.ClearDeadClients;
begin
  Sessions.CleanupSessions;
  FConnectedClients.ClearDeadClients;
end;

procedure TWebClientsContainer.DoMaintainingStep;
begin
  ClearDeadClients; // delete all timeouted clients
  if Application.NetDebugMode then
    PREP_DeleteOldNetRequests.Execute([]);
  Clients.IdleLiveClients;  // refresh all clients with no syn connection to
                            // prevent memory overflows
//  SeqSheduleStep;   // shedule clients seq
end;

function TWebClientsContainer.GetWebCachedItem(const aLoc: String
  ): TWebCachedItem;
begin
  Result := FCachedPages[aLoc];
  if not Assigned(Result) then
  begin
    Result := TWebCachedItem.Create(aLoc);
    FCachedPages.AddNew(aLoc, Result);
  end;
  Result.Refresh;
end;

Initialization
  InitHTTP;

Finalization
  DoneHTTP;

end.
