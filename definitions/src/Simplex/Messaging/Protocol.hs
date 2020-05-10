{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoStarIsType #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE UndecidableInstances #-}

module Simplex.Messaging.Protocol where

import Simplex.Messaging.Types

import ClassyPrelude
import Data.Kind
import Data.Singletons
import Data.Singletons.ShowSing
import Data.Singletons.TH
import Data.Type.Bool
import Data.Type.Predicate
import Data.Type.Predicate.Auto
import GHC.TypeLits

$(singletons [d|
  data Participant = Recipient | Broker | Sender

  data ConnectionState =  None      -- (all) not available or removed from the broker
                        | New       -- (participants: all) connection created (or received from sender)
                        | Pending   -- (recipient) sent to sender out-of-band
                        | Confirmed -- (recipient) confirmed by sender with the broker
                        | Secured   -- (all) secured with the broker
                        | Disabled  -- (broker, recipient) disabled with the broker by recipient
                        | Drained   -- (broker, recipient) drained (no messages)
    deriving (Show, ShowSing, Eq)
  |])

-- broker connection states
type Prf1 t a = Auto (TyPred t) a

data BrokerCS :: ConnectionState -> Type where
  BrkNew      :: BrokerCS 'New
  BrkSecured  :: BrokerCS 'Secured
  BrkDisabled :: BrokerCS 'Disabled
  BrkDrained  :: BrokerCS 'Drained
  BrkNone     :: BrokerCS 'None

instance Auto (TyPred BrokerCS) 'New      where auto = autoTC
instance Auto (TyPred BrokerCS) 'Secured  where auto = autoTC
instance Auto (TyPred BrokerCS) 'Disabled where auto = autoTC
instance Auto (TyPred BrokerCS) 'Drained  where auto = autoTC
instance Auto (TyPred BrokerCS) 'None     where auto = autoTC

-- sender connection states
data SenderCS :: ConnectionState -> Type where
  SndNew       :: SenderCS 'New
  SndConfirmed :: SenderCS 'Confirmed
  SndSecured   :: SenderCS 'Secured
  SndNone      :: SenderCS 'None

instance Auto (TyPred SenderCS) 'New       where auto = autoTC
instance Auto (TyPred SenderCS) 'Confirmed where auto = autoTC
instance Auto (TyPred SenderCS) 'Secured   where auto = autoTC
instance Auto (TyPred SenderCS) 'None      where auto = autoTC

-- allowed participant connection states
data HasState (p :: Participant) (s :: ConnectionState) :: Type where
  RcpHasState :: HasState 'Recipient s
  BrkHasState :: Prf1 BrokerCS s => HasState 'Broker s
  SndHasState :: Prf1 SenderCS s => HasState 'Sender s

class Prf t p s where auto' :: t p s
instance                    Prf HasState 'Recipient s
  where auto' = RcpHasState
instance Prf1 BrokerCS s => Prf HasState 'Broker s
  where auto' = BrkHasState
instance Prf1 SenderCS s => Prf HasState 'Sender s
  where auto' = SndHasState

-- established connection states (used by broker and recipient)
data EstablishedState (s :: ConnectionState) :: Type where
  ESecured  :: EstablishedState 'Secured
  EDisabled :: EstablishedState 'Disabled
  EDrained  :: EstablishedState 'Drained


-- data types for connection states of all participants
infixl 7 <==>, <==|   -- types
infixl 7 :<==>, :<==| -- constructors

data (<==>) (rs :: ConnectionState) (bs :: ConnectionState) :: Type where
  (:<==>) :: (Prf HasState 'Recipient rs, Prf HasState 'Broker bs)
          => Sing rs
          -> Sing bs
          -> rs <==> bs

deriving instance Show (rs <==> bs)

data AllConnState (rs :: ConnectionState)
                  (bs :: ConnectionState)
                  (ss :: ConnectionState) :: Type where
  (:<==|) :: Prf HasState 'Sender ss
          => rs <==> bs
          -> Sing ss
          -> AllConnState rs bs ss

deriving instance Show (AllConnState rs bs ss)

type family (<==|) rb ss where
  (rs <==> bs) <==| (ss :: ConnectionState) = AllConnState rs bs ss

--   recipient <==> broker <==| sender
st2 :: 'Pending <==> 'New <==| 'Confirmed
st2 = SPending :<==> SNew :<==| SConfirmed

-- this must not type check
-- stBad :: 'Pending <==> 'Confirmed <==| 'Confirmed
-- stBad = SPending :<==> SConfirmed :<==| SConfirmed


infixl 4 :>>, :>>=

data Command a (from :: Participant) (to :: Participant)
               state state'
               (subscribed :: Bool) (subscribed' :: Bool)
               :: Type where
  CreateConn   :: Prf HasState 'Sender s
               => CreateConnRequest
               -> Command CreateConnResponse
                    'Recipient 'Broker
                    ('None <==> 'None <==| s)
                    ('New <==> 'New  <==| s)
                    'False 'False

  Subscribe    :: ( (r /= 'None && r /= 'Disabled) ~ 'True
                  , (b /= 'None && b /= 'Disabled) ~ 'True
                  , Prf HasState 'Sender s )
               => Command ()
                    'Recipient 'Broker
                    (r <==> b <==| s)
                    (r <==> b <==| s)
                    'False 'True

  Unsubscribe  :: ( (r /= 'None && r /= 'Disabled) ~ 'True
                  , (b /= 'None && b /= 'Disabled) ~ 'True
                  , Prf HasState 'Sender s )
               => Command ()
                    'Recipient 'Broker
                    (r <==> b <==| s)
                    (r <==> b <==| s)
                    'True 'False

  SendInvite   :: Prf HasState 'Broker s
               => String -- invitation - TODO
               -> Command ()
                    'Recipient 'Sender
                    ('New <==> s <==| 'None)
                    ('Pending <==> s <==| 'New)
                    ss ss

  ConfirmConn  :: Prf HasState 'Recipient s
               => SecureConnRequest
               -> Command ()
                    'Sender 'Broker
                    (s <==> 'New <==| 'New)
                    (s <==> 'New <==| 'Confirmed)
                    ss ss

  PushConfirm  :: Prf HasState 'Sender s
               => Command SecureConnRequest
                    'Broker 'Recipient
                    ('Pending <==> 'New <==| s)
                    ('Confirmed <==> 'New <==| s)
                    'True 'True

  SecureConn   :: Prf HasState 'Sender s
               => SecureConnRequest
               -> Command ()
                    'Recipient 'Broker
                    ('Confirmed <==> 'New <==| s)
                    ('Secured <==> 'Secured <==| s)
                    ss ss

  SendWelcome  :: Prf HasState 'Recipient s
               => Command ()
                    'Sender 'Broker
                    (s <==> 'Secured <==| 'Confirmed)
                    (s <==> 'Secured <==| 'Secured)
                    ss ss

  SendMsg      :: Prf HasState 'Recipient s
               => SendMessageRequest
               -> Command ()
                    'Sender 'Broker
                    (s <==> 'Secured <==| 'Secured)
                    (s <==> 'Secured <==| 'Secured)
                    ss ss

  PushMsg      :: Prf HasState 'Sender s
               => Command MessagesResponse -- TODO, has to be a single message
                    'Broker 'Recipient
                    ('Secured <==> 'Secured <==| s)
                    ('Secured <==> 'Secured <==| s)
                    'True 'True

  DeleteMsg    :: Prf HasState 'Sender s   -- TODO needs message ID parameter
               => Command ()
                    'Recipient 'Broker
                    ('Secured <==> 'Secured <==| s)
                    ('Secured <==> 'Secured <==| s)
                    ss ss

  Return       :: a -> Command a from to state state ss ss

  (:>>)        :: Command a from1 to1 s1 s2 ss1 ss2
               -> Command b from2 to2 s2 s3 ss2 ss3
               -> Command b from1 to2 s1 s3 ss1 ss3

  (:>>=)       :: Command a from1 to1 s1 s2 ss1 ss2
               -> (a -> Command b from2 to2 s2 s3 ss2 ss3)
               -> Command b from1 to2 s1 s3 ss1 ss3


infix 6 ==>
(==>) :: from -> to -> (from, to)
from ==> to = (from, to)

infix 5 &:
(&:) :: (Sing from, Sing to)
     -> Command a from to s1 s2 ss1 ss2
     -> Command a from to s1 s2 ss1 ss2
(&:) _ c = c
