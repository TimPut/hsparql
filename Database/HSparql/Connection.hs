module Database.HSparql.Connection
    ( Database.HSparql.Connection.EndPoint
    , BindingValue(..)
    , selectQuery
    , constructQuery
    , askQuery
    , updateQuery
    , describeQuery
    )
where

import Control.Monad
import Data.Maybe
import Network.HTTP
import Text.XML.Light
import Database.HSparql.QueryGenerator
import Text.RDF.RDF4H.TurtleParser
import Data.RDF
import qualified Data.Text as T
import qualified Data.Text.Encoding as E
import qualified Data.ByteString.Char8 as B

import Network.URI hiding (URI)

-- |URI of the SPARQL endpoint.
type EndPoint = String

-- |Local representations of incoming XML results.
data BindingValue = Bound Data.RDF.Node    -- ^RDF Node (UNode, BNode, LNode)
                  | Unbound       -- ^Unbound result value
  deriving (Show, Eq)

-- |Base 'QName' for results with a SPARQL-result URI specified.
sparqlResult :: String -> QName
sparqlResult s = (unqual s) { qURI = Just "http://www.w3.org/2005/sparql-results#" }

-- |Transform the 'String' result from the HTTP request into a two-dimensional
--  table storing the bindings for each variable in each row.
structureContent :: String -> Maybe [[BindingValue]]
structureContent s =
    do e <- doc
       return $ map (projectResult $ vars e) $ findElements (sparqlResult "result") e
    where doc :: Maybe Element
          doc = parseXMLDoc s

          vars :: Element -> [String]
          vars = mapMaybe (findAttr $ unqual "name") . findElements (sparqlResult "variable")

          projectResult :: [String] -> Element -> [BindingValue]
          projectResult vs e = map pVar vs
             where pVar v   = maybe Unbound (value . head . elChildren) $ filterElement (pred v) e
                   pred v e = isJust $ do a <- findAttr (unqual "name") e
                                          guard $ a == v

          value :: Element -> BindingValue
          value e =
            case qName (elName e) of
              "uri"     -> Bound $ Data.RDF.unode $ (T.pack $ strContent e)
              "literal" -> case findAttr (unqual "datatype") e of
                             Just dt -> Bound $ Data.RDF.lnode $ Data.RDF.typedL (T.pack $ strContent e) (T.pack dt)
                             Nothing -> case findAttr langAttr e of
                                          Just lang -> Bound $ Data.RDF.lnode $ Data.RDF.plainLL (T.pack $ strContent e) (T.pack lang)
                                          Nothing   -> Bound $ Data.RDF.lnode $ Data.RDF.plainL (T.pack $ strContent e)
              -- TODO: what about blank nodes?
              _         -> Unbound

          langAttr :: QName
          langAttr = blank_name { qName = "lang", qPrefix = Just "xml" }

-- |Parses the response from a SPARQL ASK query. Either "true" or "false" is expected
parseAsk :: String -> Bool
parseAsk s
  | (s' == "true" || s' == "yes") = True
  | (s' == "false"|| s' == "no")  = False
  | otherwise = error $ "Unexpected Ask response: " ++ s
 where
  s' = reverse $ dropWhile (=='\n') $ reverse s

-- |Parses the response from a SPARQL UPDATE query.  An empty body is expected
parseUpdate :: String -> Bool
parseUpdate s
  | s == "" = True
  | otherwise = error $ "Unexpected Update response: " ++ s

-- |Connect to remote 'EndPoint' and find all possible bindings for the
--  'Variable's in the 'SelectQuery' action.
selectQuery :: Database.HSparql.Connection.EndPoint -> Query SelectQuery -> IO (Maybe [[BindingValue]])
selectQuery ep q = do
    let uri      = ep ++ "?" ++ urlEncodeVars [("query", createSelectQuery q)]
        h1 = mkHeader HdrAccept "application/sparql-results+xml"
        h2 = mkHeader HdrUserAgent "hsparql-client"
        request = Request { rqURI = fromJust $ parseURI uri
                          , rqHeaders = [h1,h2]
                          , rqMethod = GET
                          , rqBody = ""
                          }
    response <- simpleHTTP request >>= getResponseBody
    return $ structureContent response

-- |Connect to remote 'EndPoint' and find all possible bindings for the
--  'Variable's in the 'SelectQuery' action.
askQuery :: Database.HSparql.Connection.EndPoint -> Query AskQuery -> IO Bool
askQuery ep q = do
    let uri = ep ++ "?" ++ urlEncodeVars [("query", createAskQuery q)]
        hdr1 = Header HdrUserAgent "hsparql-client"
        hdr2 = Header HdrAccept "text/plain"
        hdr3 = Header HdrAccept "text/boolean"
        hdr4 = Header HdrAcceptCharset "utf-8"
        request  = insertHeaders [hdr1,hdr2,hdr3,hdr4] (getRequest uri)
    response <- simpleHTTP request >>= getResponseBody
    return $ parseAsk response


-- |Connect to remote 'EndPoint' and find all possible bindings for the
--  'Variable's in the 'SelectQuery' action.
updateQuery :: Database.HSparql.Connection.EndPoint -> Query UpdateQuery -> IO Bool
updateQuery ep q = do
    let uri = ep
        body = createUpdateQuery q
        h1 = mkHeader HdrContentLength $ show (length body)
        h2 = mkHeader HdrContentType "application/sparql-update"
        h3 = mkHeader HdrUserAgent "hsparql-client"
        request = Request { rqURI = fromJust $ parseURI uri
                          , rqHeaders = [h1,h2,h3]
                          , rqMethod = POST
                          , rqBody = body
                          }
    response <- simpleHTTP request >>= getResponseBody
--    return $ structureContent response
    return $ parseUpdate response


-- |Connect to remote 'EndPoint' and construct 'TriplesGraph' from given
--  'ConstructQuery' action. /Provisional implementation/.
constructQuery :: (Rdf a) => Database.HSparql.Connection.EndPoint -> Query ConstructQuery -> IO (RDF a)
constructQuery ep q = do
    let uri      = ep ++ "?" ++ urlEncodeVars [("query", createConstructQuery q)]
    rdfGraph <- httpCallForRdf uri
    case rdfGraph of
      Left e -> error $ show e
      Right graph -> return graph
   

-- |Connect to remote 'EndPoint' and construct 'TriplesGraph' from given
--  'ConstructQuery' action. /Provisional implementation/.
describeQuery :: (Rdf a) => Database.HSparql.Connection.EndPoint -> Query DescribeQuery -> IO (RDF a)
describeQuery ep q = do
    let uri      = ep ++ "?" ++ urlEncodeVars [("query", createDescribeQuery q)]
    rdfGraph <- httpCallForRdf uri
    case rdfGraph of
      Left e -> error $ show e
      Right graph -> return graph
    
-- |Takes a generated uri and makes simple HTTP request,
-- asking for RDF N3 serialization. Returns either 'ParseFailure' or 'RDF'
httpCallForRdf :: Rdf a => String -> IO (Either ParseFailure (RDF a))
httpCallForRdf uri = do
  let h1 = mkHeader HdrUserAgent "hsparql-client"
      h2 = mkHeader HdrAccept "text/turtle"
      request = Request { rqURI = fromJust $ parseURI uri
                          , rqHeaders = [h1,h2]
                          , rqMethod = GET
                          , rqBody = ""
                          }
  response <- simpleHTTP request >>= getResponseBody
  return $ parseString (TurtleParser Nothing Nothing) $ E.decodeUtf8 (B.pack response)
